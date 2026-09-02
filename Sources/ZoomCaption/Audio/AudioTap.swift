import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// MARK: - Core Audio 헬퍼

private func sysAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel,
                             mScope: kAudioObjectPropertyScopeGlobal,
                             mElement: kAudioObjectPropertyElementMain)
}

struct AudioProcessInfo {
  let objectID: AudioObjectID
  let pid: pid_t
  let bundleID: String
}

enum CoreAudioInfo {
  /// 현재 시스템에 등록된 오디오 프로세스 목록
  static func processes() -> [AudioProcessInfo] {
    var addr = sysAddr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }

    return ids.map { oid in
      var a = sysAddr(kAudioProcessPropertyPID)
      var pid: pid_t = -1
      var s = UInt32(MemoryLayout<pid_t>.size)
      AudioObjectGetPropertyData(oid, &a, 0, nil, &s, &pid)

      a = sysAddr(kAudioProcessPropertyBundleID)
      var cf: CFString?
      s = UInt32(MemoryLayout<CFString?>.size)
      AudioObjectGetPropertyData(oid, &a, 0, nil, &s, &cf)
      return AudioProcessInfo(objectID: oid, pid: pid, bundleID: (cf as String?) ?? "")
    }
  }

  /// 그 프로세스가 **지금 실제로** 소리를 내보내고 있는지.
  /// 앱이 떠 있는 것과는 다르다 — Zoom 은 회의에 안 들어가 있어도 오디오 프로세스를 갖고 있다.
  static func isPlaying(_ p: AudioProcessInfo) -> Bool {
    var a = sysAddr(kAudioProcessPropertyIsRunningOutput)
    var running: UInt32 = 0
    var s = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(p.objectID, &a, 0, nil, &s, &running) == noErr && running != 0
  }

  /// 지금 실제로 소리를 내보내고 있는 프로세스가 하나라도 있는지
  static func isAnythingPlaying() -> Bool {
    processes().contains { isPlaying($0) }
  }

  /// 지금 소리를 내고 있는 프로세스들의 번들 ID
  static func playingBundleIDs() -> [String] {
    processes().filter { isPlaying($0) }.map(\.bundleID).filter { !$0.isEmpty }
  }

  static func defaultOutputUID() -> String? {
    var addr = sysAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return nil }
    addr = sysAddr(kAudioDevicePropertyDeviceUID)
    var cf: CFString?
    size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cf) == noErr else { return nil }
    return cf as String?
  }

  /// 기본 출력 장치의 사람이 읽는 이름("AirPods", "MacBook Pro 스피커" 등).
  /// 장치 전환 알림 문구에 UID 대신 이 이름을 보여준다.
  static func defaultOutputName() -> String? {
    var addr = sysAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return nil }
    addr = sysAddr(kAudioObjectPropertyName)
    var cf: CFString?
    size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cf) == noErr else { return nil }
    return cf as String?
  }

  /// 기본 출력 장치가 바뀔 때마다 `onChange` 를 부른다(이어폰 꽂기/빼기 등).
  ///
  /// 녹음 시작·정지마다 구독을 다시 걸 필요 없이 앱 켤 때 한 번만 등록해 두고,
  /// 녹음 중인지는 콜백을 받는 쪽에서 판단하게 한다 — 하루에 여러 번 시작·정지해도
  /// 등록/해제를 반복하다 꼬일 일이 없다.
  ///
  /// CoreAudio 의 HAL 알림 스레드를 오래 붙잡지 않도록, 콜백은 우리가 지정한
  /// 전역 큐에서 돌게 한다(`inDispatchQueue`에 nil을 주면 그 내부 스레드에서 바로 실행됨).
  static func watchDefaultOutputDevice(onChange: @escaping @Sendable () -> Void) {
    var addr = sysAddr(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global()
    ) { _, _ in onChange() }
  }
}

// MARK: - 시스템 오디오 탭

/// Core Audio process tap으로 다른 앱(Zoom 등)의 재생 오디오를 가로챈다.
/// 스피커 출력은 그대로 유지되므로 사용자는 평소처럼 소리를 들으면서 캡처된다.
final class SystemAudioTap: @unchecked Sendable {
  enum TapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case noOutputDevice
    case formatUnavailable

    var errorDescription: String? {
      switch self {
      case .tapCreationFailed(let s): return "오디오 탭 생성 실패 (OSStatus \(s))"
      case .aggregateCreationFailed(let s): return "집합 장치 생성 실패 (OSStatus \(s))"
      case .ioProcFailed(let s): return "오디오 콜백 등록 실패 (OSStatus \(s))"
      case .noOutputDevice: return "기본 출력 장치를 찾을 수 없습니다"
      case .formatUnavailable: return "탭의 오디오 포맷을 읽을 수 없습니다"
      }
    }
  }

  /// Zoom 계열 번들 ID. 회의 오디오는 us.zoom.xos 가 담당한다.
  static let zoomBundleIDs: Set<String> = [
    "us.zoom.xos", "us.zoom.ZoomClips", "us.zoom.ZoomLauncher", "us.zoom.ZoomAudioDaemon",
  ]

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var tapUUID: UUID?

  private(set) var sourceFormat: AVAudioFormat?
  private let onBuffer: (AVAudioPCMBuffer) -> Void

  /// 캡처된 샘플이 전부 0인지 감시한다. 권한이 없으면 macOS는 에러 대신 무음을 준다.
  private let silenceLock = NSLock()
  private var _framesSeen: Int = 0
  private var _lastNonSilentAt: Date?
  // 입력 레벨. 정규화(게인 보정)가 필요한지 판단하는 근거로 쓴다.
  private var _peak: Float = 0
  private var _sumSquares: Double = 0
  private var _sampleCount: Int = 0

  /// 무음 판정 기준(초). Whisper 청크 주기(30초)와 맞춰 뒀다 — 나중에 "무음일 때
  /// Whisper 가 실시간을 따라잡느라 대기만 하고 처리를 안 하는" 문제를 풀 때
  /// 이 값을 그대로 재사용할 것.
  static let recentSoundWindow: TimeInterval = 30

  var framesSeen: Int { silenceLock.withLock { _framesSeen } }

  /// 마지막으로 소리를 들은 뒤 지난 시간(초). 계속 듣고 있으면 0에 가깝고,
  /// 이번 탭을 시작한 뒤로 한 번도 못 들었으면 nil. 기존엔 "이 탭이 시작된 뒤로
  /// 평생 한 번이라도 들었는지"만 재는 누적 카운터였는데, 그러면 정상적으로
  /// 잘 듣다가 중간에(예: 이어폰 전환으로) 죽어도 다시는 안 걸렸다. 지금은 시각
  /// 하나만 들고 있다가 "지금으로부터 얼마나 지났는지"를 매번 다시 재므로,
  /// 30초든 강의 쉬는 시간(5~8분, 별도 논의)이든 부르는 쪽이 원하는 기준을
  /// 각자 적용할 수 있다.
  var silenceDuration: TimeInterval? {
    silenceLock.withLock {
      guard let last = _lastNonSilentAt else { return nil }
      return Date().timeIntervalSince(last)
    }
  }

  /// 최근 recentSoundWindow(30초) 안에 소리를 들었는지.
  var isHearingSound: Bool { (silenceDuration ?? .infinity) < Self.recentSoundWindow }

  /// 지금까지 관측한 최대 진폭 (0~1)
  var peakLevel: Float { silenceLock.withLock { _peak } }
  /// 전체 구간 RMS (0~1). 말소리가 섞인 구간 평균이라 대체로 peak 보다 훨씬 작다.
  var rmsLevel: Double {
    silenceLock.withLock { _sampleCount > 0 ? (_sumSquares / Double(_sampleCount)).squareRoot() : 0 }
  }
  /// dBFS 로 본 peak. -20 dBFS 이하로 계속 머무르면 입력이 작은 편이다.
  var peakDBFS: Double {
    let p = Double(peakLevel)
    return p > 0 ? 20 * log10(p) : -.infinity
  }

  init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
    self.onBuffer = onBuffer
  }

  /// - Parameter zoomOnly: true면 Zoom 프로세스만, false면 시스템 전체 오디오를 캡처
  func start(zoomOnly: Bool) throws {
    let targets = CoreAudioInfo.processes()
      .filter { Self.zoomBundleIDs.contains($0.bundleID) }
      .map(\.objectID)

    // Zoom이 안 떠 있으면 전체 탭으로 자동 전환한다 (수업 전 미리 켜두는 경우 대비).
    let desc: CATapDescription = (zoomOnly && !targets.isEmpty)
      ? CATapDescription(stereoMixdownOfProcesses: targets)
      : CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    let uuid = UUID()
    desc.name = "ZoomCaption"
    desc.uuid = uuid
    desc.isPrivate = true
    desc.muteBehavior = .unmuted   // 사용자는 계속 소리를 들을 수 있어야 한다
    tapUUID = uuid

    var tap = AudioObjectID(kAudioObjectUnknown)
    let tapErr = AudioHardwareCreateProcessTap(desc, &tap)
    guard tapErr == noErr else { throw TapError.tapCreationFailed(tapErr) }
    tapID = tap

    var fmtAddr = sysAddr(kAudioTapPropertyFormat)
    var asbd = AudioStreamBasicDescription()
    var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fsize, &asbd) == noErr,
          let fmt = AVAudioFormat(streamDescription: &asbd)
    else { throw TapError.formatUnavailable }
    sourceFormat = fmt

    guard let outUID = CoreAudioInfo.defaultOutputUID() else { throw TapError.noOutputDevice }

    let aggDesc: [String: Any] = [
      kAudioAggregateDeviceNameKey: "ZoomCaption Aggregate",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: uuid.uuidString,
      ]],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
    guard aggErr == noErr else { throw TapError.aggregateCreationFailed(aggErr) }
    aggregateID = agg

    var proc: AudioDeviceIOProcID?
    let ioErr = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [weak self] _, inData, _, _, _ in
      self?.handle(inData)
    }
    guard ioErr == noErr, let proc else { throw TapError.ioProcFailed(ioErr) }
    ioProcID = proc

    let startErr = AudioDeviceStart(agg, proc)
    guard startErr == noErr else { throw TapError.ioProcFailed(startErr) }
  }

  private func handle(_ inData: UnsafePointer<AudioBufferList>) {
    guard let fmt = sourceFormat else { return }
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard let first = abl.first, let mData = first.mData, first.mDataByteSize > 0 else { return }

    let bytesPerFrame = fmt.streamDescription.pointee.mBytesPerFrame
    guard bytesPerFrame > 0 else { return }
    let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
    guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
    buf.frameLength = frames

    guard let dst = buf.audioBufferList.pointee.mBuffers.mData else { return }
    memcpy(dst, mData, Int(first.mDataByteSize))

    // 무음 감시(권한 미승인 시 프레임은 오지만 값이 전부 0이다)와 레벨 측정을 함께 한다.
    var nonSilent = false
    var peak: Float = 0
    var sumSquares = 0.0
    var counted = 0
    if fmt.commonFormat == .pcmFormatFloat32, let ch = buf.floatChannelData {
      let n = Int(frames) * Int(fmt.isInterleaved ? fmt.channelCount : 1)
      let p = ch[0]
      // 오디오 콜백이라 전수 검사는 피하고 4샘플마다 훑는다.
      for i in stride(from: 0, to: n, by: 4) {
        let v = abs(p[i])
        if v > 1e-5 { nonSilent = true }
        if v > peak { peak = v }
        sumSquares += Double(v) * Double(v)
        counted += 1
      }
    }
    silenceLock.lock()
    _framesSeen += Int(frames)
    if nonSilent { _lastNonSilentAt = Date() }
    if peak > _peak { _peak = peak }
    _sumSquares += sumSquares
    _sampleCount += counted
    silenceLock.unlock()

    onBuffer(buf)
  }

  func stop() {
    if aggregateID != AudioObjectID(kAudioObjectUnknown), let proc = ioProcID {
      AudioDeviceStop(aggregateID, proc)
      AudioDeviceDestroyIOProcID(aggregateID, proc)
    }
    if aggregateID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregateID)
    }
    if tapID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(tapID)
    }
    ioProcID = nil
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
    silenceLock.withLock {
      _framesSeen = 0; _lastNonSilentAt = nil
      _peak = 0; _sumSquares = 0; _sampleCount = 0
    }
  }

  deinit { stop() }
}

// MARK: - 리샘플러

/// 임의 입력 포맷을 SpeechAnalyzer가 요구하는 포맷(16kHz mono Int16)으로 변환한다.
final class AudioResampler: @unchecked Sendable {
  private let target: AVAudioFormat
  private var converter: AVAudioConverter?
  private var currentInput: AVAudioFormat?
  private let lock = NSLock()

  init(target: AVAudioFormat) { self.target = target }

  func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    lock.lock()
    defer { lock.unlock() }

    if currentInput != input.format || converter == nil {
      converter = AVAudioConverter(from: input.format, to: target)
      converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
      currentInput = input.format
    }
    guard let converter else { return nil }

    let ratio = target.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

    var supplied = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return input
    }

    guard status != .error, out.frameLength > 0 else { return nil }
    return out
  }
}

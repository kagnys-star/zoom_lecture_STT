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

/// 시스템 탭과 관리자 파일 되먹임이 함께 쓰는 오디오 활동 시계다.
///
/// 이 상태를 `SystemAudioTap` 안에만 두면 실제 장치를 거치지 않는 `AdminFeed`에서는
/// 180초 무음 동작을 재현할 수 없다. 그래서 오디오를 전사 파이프라인에 넣기 직전에
/// 같은 시계를 갱신하도록 분리했다. 새 타이머를 따로 증가시키지 않고, 기존 구현처럼
/// **마지막으로 유효한 소리를 본 절대 시각** 하나만 저장한 뒤 필요할 때 경과 시간을
/// 계산한다. 시스템 절전이나 타이머 지연이 있어도 누적 오차가 생기지 않는 이유다.
final class AudioActivityClock: @unchecked Sendable {
  /// 한 무음 구간을 식별하는 불변 스냅샷이다. 비동기 Whisper 대기를 마친 뒤에도
  /// `lastNonSilentAt`이 같아야 같은 무음이 계속된 것으로 인정한다. 그 사이 새 소리가
  /// 한 번이라도 들어오면 시각이 달라지므로 오래된 작업이 `volatile`을 지우지 못한다.
  struct SilencePeriod: Sendable {
    let lastNonSilentAt: Date
    let measuredAt: Date

    var duration: TimeInterval { measuredAt.timeIntervalSince(lastNonSilentAt) }
  }

  /// 캡처 이상 알림에 쓰는 짧은 기준이다. 강의 종료 경계(180초)는 앱 수명주기에서
  /// 별도로 적용한다. 서로 목적이 다른 두 기준을 같은 상수로 묶으면 한쪽 조정이
  /// 다른 동작까지 바꾸므로 분리해 둔다.
  static let recentSoundWindow: TimeInterval = 30

  private let lock = NSLock()
  private var framesObserved = 0
  private var lastNonSilentAt: Date?
  private var maximumPeakLevel: Float = 0
  private var accumulatedSquaredSamples: Double = 0
  private var measuredSampleCount = 0

  /// 버퍼를 한 번 관측해 마지막 유효 소리 시각과 입력 레벨 통계를 함께 갱신한다.
  /// 오디오 콜백을 오래 막지 않도록 4샘플마다 하나만 읽는다. Float32와 Int16을 모두
  /// 처리하므로 시스템 탭뿐 아니라 서로 다른 포맷의 관리자 시험 WAV에도 동작한다.
  func observe(_ buffer: AVAudioPCMBuffer, observedAt: Date = Date()) {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return }

    let channelCount = Int(buffer.format.channelCount)
    let samplesPerChannel = buffer.format.isInterleaved ? frameCount * channelCount : frameCount
    var containsAudibleSample = false
    var bufferPeakLevel: Float = 0
    var bufferSquaredSampleSum = 0.0
    var bufferMeasuredSampleCount = 0

    if buffer.format.commonFormat == .pcmFormatFloat32, let channelData = buffer.floatChannelData {
      let samples = channelData[0]
      for sampleIndex in stride(from: 0, to: samplesPerChannel, by: 4) {
        let absoluteLevel = abs(samples[sampleIndex])
        if absoluteLevel > 1e-5 { containsAudibleSample = true }
        bufferPeakLevel = max(bufferPeakLevel, absoluteLevel)
        bufferSquaredSampleSum += Double(absoluteLevel) * Double(absoluteLevel)
        bufferMeasuredSampleCount += 1
      }
    } else if buffer.format.commonFormat == .pcmFormatInt16,
              let channelData = buffer.int16ChannelData {
      let samples = channelData[0]
      for sampleIndex in stride(from: 0, to: samplesPerChannel, by: 4) {
        // Int16.min의 절댓값은 Int16 범위를 넘으므로 먼저 Int로 넓힌다.
        let absoluteIntegerLevel = abs(Int(samples[sampleIndex]))
        let normalizedLevel = Float(absoluteIntegerLevel) / Float(Int16.max)
        if normalizedLevel > 1e-5 { containsAudibleSample = true }
        bufferPeakLevel = max(bufferPeakLevel, normalizedLevel)
        bufferSquaredSampleSum += Double(normalizedLevel) * Double(normalizedLevel)
        bufferMeasuredSampleCount += 1
      }
    }

    lock.withLock {
      framesObserved += frameCount
      if containsAudibleSample { lastNonSilentAt = observedAt }
      maximumPeakLevel = max(maximumPeakLevel, bufferPeakLevel)
      accumulatedSquaredSamples += bufferSquaredSampleSum
      measuredSampleCount += bufferMeasuredSampleCount
    }
  }

  var framesSeen: Int { lock.withLock { framesObserved } }

  /// 마지막 유효 소리 이후 현재까지 이어진 무음 구간. 녹음을 시작한 뒤 아직 소리를
  /// 한 번도 듣지 못했다면 강의가 시작됐다고 볼 근거가 없으므로 nil을 반환한다.
  var silencePeriod: SilencePeriod? {
    lock.withLock {
      guard let lastNonSilentAt else { return nil }
      return SilencePeriod(lastNonSilentAt: lastNonSilentAt, measuredAt: Date())
    }
  }

  var silenceDuration: TimeInterval? { silencePeriod?.duration }

  var isHearingSound: Bool {
    (silenceDuration ?? .infinity) < Self.recentSoundWindow
  }

  /// 비동기 작업 전후가 같은 무음 구간인지 원자적으로 재검사한다. 단순히 현재
  /// `silenceDuration >= 180`만 검사하면, 중간에 소리가 재개됐다가 다시 끊긴 짧은
  /// 새 무음 구간을 오래된 작업이 잘못 확정할 수 있다.
  func hasMaintainedSilence(_ expectedPeriod: SilencePeriod,
                            forAtLeast minimumDuration: TimeInterval) -> Bool {
    lock.withLock {
      guard lastNonSilentAt == expectedPeriod.lastNonSilentAt,
            let lastNonSilentAt
      else { return false }
      return Date().timeIntervalSince(lastNonSilentAt) >= minimumDuration
    }
  }

  var peakLevel: Float { lock.withLock { maximumPeakLevel } }

  var rmsLevel: Double {
    lock.withLock {
      guard measuredSampleCount > 0 else { return 0 }
      return (accumulatedSquaredSamples / Double(measuredSampleCount)).squareRoot()
    }
  }

  var peakDBFS: Double {
    let normalizedPeakLevel = Double(peakLevel)
    return normalizedPeakLevel > 0 ? 20 * log10(normalizedPeakLevel) : -.infinity
  }
}

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

    // 무음 시계는 실제 시스템 탭과 관리자 되먹임이 공유해야 하므로, 이 계층에서는
    // 샘플을 판정하지 않고 공통 onBuffer 파이프라인에 그대로 넘긴다.
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

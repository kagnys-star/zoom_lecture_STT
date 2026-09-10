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

struct AudioProcessInfo: Sendable {
  let objectID: AudioObjectID
  let pid: pid_t
  let bundleID: String
}

/// 관리자 A/B 진단 화면에만 노출하는 출력 스트림 정보다. `streamIndex`는
/// CATapDescription의 device/stream 초기화가 요구하는 장치 내 순번이고,
/// `objectID`는 같은 순번이 실제 어느 HAL 스트림이었는지 로그로 남기기 위한 값이다.
struct AudioOutputStreamInfo: Sendable {
  let streamIndex: UInt
  let objectID: AudioStreamID
}

/// 한 오디오 프로세스가 현재 출력에 사용하는 장치와 그 출력 스트림 목록이다.
/// 이 정보는 아직 운영 캡처 경로를 결정하지 않으며 관리자 A/B 후보를 열거하는 데만 쓴다.
struct AudioProcessOutputDeviceInfo: Sendable {
  let objectID: AudioDeviceID
  let uid: String
  let name: String
  let streams: [AudioOutputStreamInfo]
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

  /// 프로세스가 출력 I/O를 실행하며 활성 출력 스트림을 가지고 있는지 확인한다.
  ///
  /// Core Audio의 `kAudioProcessPropertyIsRunningOutput`은 스트림 안에 실제 음성
  /// 샘플이 있다는 뜻이 아니다. Zoom은 발표자가 침묵해도 0 PCM을 보내면서 출력
  /// 스트림을 열어 둘 수 있으므로, 이 값을 `isPlaying`처럼 해석하면 정상 무음을
  /// 캡처 장애로 오인한다. 이 값은 경로 진단의 보조 정보로만 사용해야 한다.
  static func hasActiveOutputIO(_ audioProcess: AudioProcessInfo) -> Bool {
    var a = sysAddr(kAudioProcessPropertyIsRunningOutput)
    var running: UInt32 = 0
    var s = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(audioProcess.objectID, &a, 0, nil, &s, &running) == noErr
      && running != 0
  }

  /// 활성 출력 I/O를 가진 프로세스가 하나라도 있는지 확인한다. 이 반환값만으로
  /// 시스템에 사람이 들을 수 있는 소리가 재생 중이라고 판단하면 안 된다.
  static func hasAnyProcessWithActiveOutputIO() -> Bool {
    processes().contains { hasActiveOutputIO($0) }
  }

  /// 활성 출력 I/O를 가진 프로세스들의 번들 ID. 실제 audible sample 목록이 아니라
  /// HAL 경로 상태 목록이라는 의미가 이름에서 드러나도록 한다.
  static func activeOutputIOBundleIDs() -> [String] {
    processes().filter { hasActiveOutputIO($0) }.map(\.bundleID).filter { !$0.isEmpty }
  }

  /// 관리자가 프로세스별·장치별·스트림별로 실제 음성 출처를 비교할 수 있도록
  /// 해당 프로세스가 현재 출력에 사용하는 장치를 조회한다. `scopeOutput`을 쓰지
  /// 않으면 마이크 입력 장치도 같은 목록에 섞여 A/B 결과를 잘못 해석할 수 있다.
  static func outputDevices(usedBy audioProcess: AudioProcessInfo)
    -> [AudioProcessOutputDeviceInfo] {
    var processDevicesAddress = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyDevices,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var processDevicesDataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      audioProcess.objectID, &processDevicesAddress, 0, nil, &processDevicesDataSize) == noErr
    else { return [] }

    var outputDeviceObjectIDs = [AudioDeviceID](
      repeating: AudioDeviceID(kAudioObjectUnknown),
      count: Int(processDevicesDataSize) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      audioProcess.objectID,
      &processDevicesAddress,
      0,
      nil,
      &processDevicesDataSize,
      &outputDeviceObjectIDs) == noErr
    else { return [] }

    return outputDeviceObjectIDs.compactMap { outputDeviceObjectID in
      guard let outputDeviceUID = stringProperty(
        objectID: outputDeviceObjectID,
        selector: kAudioDevicePropertyDeviceUID)
      else { return nil }
      let outputDeviceName = stringProperty(
        objectID: outputDeviceObjectID,
        selector: kAudioObjectPropertyName) ?? "알 수 없는 장치"
      return AudioProcessOutputDeviceInfo(
        objectID: outputDeviceObjectID,
        uid: outputDeviceUID,
        name: outputDeviceName,
        streams: outputStreams(of: outputDeviceObjectID))
    }
  }

  /// 장치의 출력 스트림을 HAL이 반환한 순서대로 보존한다. CATapDescription은
  /// AudioStreamID가 아니라 장치 안의 stream index를 받으므로 두 값을 함께 보관한다.
  private static func outputStreams(of outputDeviceObjectID: AudioDeviceID)
    -> [AudioOutputStreamInfo] {
    var outputStreamsAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var outputStreamsDataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      outputDeviceObjectID, &outputStreamsAddress, 0, nil, &outputStreamsDataSize) == noErr
    else { return [] }

    var outputStreamObjectIDs = [AudioStreamID](
      repeating: AudioStreamID(kAudioObjectUnknown),
      count: Int(outputStreamsDataSize) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(
      outputDeviceObjectID,
      &outputStreamsAddress,
      0,
      nil,
      &outputStreamsDataSize,
      &outputStreamObjectIDs) == noErr
    else { return [] }
    return outputStreamObjectIDs.enumerated().map { streamIndex, outputStreamObjectID in
      AudioOutputStreamInfo(streamIndex: UInt(streamIndex), objectID: outputStreamObjectID)
    }
  }

  /// CFString 기반 HAL 속성을 한 방식으로 읽는다. 장치 UID와 표시 이름이 서로 다른
  /// 메모리 크기·scope를 사용해 어긋나지 않도록 관리자 진단 조회를 이 함수로 모은다.
  private static func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var propertyAddress = sysAddr(selector)
    var propertyValue: CFString?
    var propertyDataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(
      objectID, &propertyAddress, 0, nil, &propertyDataSize, &propertyValue) == noErr
    else { return nil }
    return propertyValue as String?
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

/// 캡처 범위와 실패 정책을 Boolean 대신 명시한다. 실사용 Zoom 캡처는 대상을 찾지
/// 못했을 때 시스템 전체로 넓어지면 안 되고, 전역 캡처는 격리된 관리자 시험에서만
/// 사용해야 한다. 이 타입은 Zoom을 기다리는 비동기 수명주기를 뜻하지 않는다.
enum AudioCaptureScope: String, Sendable {
  case zoomMeetingOutput
  case administratorSystemOutput
}

/// PCM 내용과 무관하게 Core Audio 콜백 전달 경로가 살아 있는지 측정한다.
/// `AudioActivityClock`은 마지막 유효 소리 시각을 맡고, 이 객체는 0 PCM을 포함한
/// 마지막 버퍼 도착 시각만 맡아 정상 침묵과 콜백 중단을 서로 구분한다.
final class AudioCaptureHeartbeat: @unchecked Sendable {
  struct Snapshot: Sendable {
    let hasReceivedAudioBuffer: Bool
    let secondsSinceMostRecentBufferOrStart: TimeInterval
  }

  private let lock = NSLock()
  private let captureStartedAtUptimeNanoseconds: UInt64
  private var lastAudioBufferArrivalUptimeNanoseconds: UInt64?

  init(captureStartedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    self.captureStartedAtUptimeNanoseconds = captureStartedAtUptimeNanoseconds
  }

  /// 오디오 값이 전부 0이어도 호출한다. 여기서 샘플 크기를 검사하면 다시 콘텐츠
  /// 무음과 전달 경로 중단을 섞게 되므로, 유효한 버퍼가 도착했다는 사실만 기록한다.
  func recordAudioBufferArrival(
    at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    lock.withLock { lastAudioBufferArrivalUptimeNanoseconds = uptimeNanoseconds }
  }

  /// 시스템 시각 변경의 영향을 받지 않는 uptime으로 현재 콜백 간격을 반환한다.
  /// 아직 첫 버퍼가 없다면 캡처 시작 이후 시간을 반환해 시작 직후 영원히 진단이
  /// 보류되는 일을 막는다.
  func snapshot(
    at currentUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> Snapshot {
    lock.withLock {
      let referenceUptimeNanoseconds = lastAudioBufferArrivalUptimeNanoseconds
        ?? captureStartedAtUptimeNanoseconds
      let elapsedNanoseconds = currentUptimeNanoseconds >= referenceUptimeNanoseconds
        ? currentUptimeNanoseconds - referenceUptimeNanoseconds
        : 0
      return Snapshot(
        hasReceivedAudioBuffer: lastAudioBufferArrivalUptimeNanoseconds != nil,
        secondsSinceMostRecentBufferOrStart: Double(elapsedNanoseconds) / 1_000_000_000)
    }
  }
}

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
    case zoomAudioProcessUnavailable
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case noOutputDevice
    case formatUnavailable

    var errorDescription: String? {
      switch self {
      case .zoomAudioProcessUnavailable:
        return "Zoom 회의 오디오 프로세스를 찾지 못했습니다. Zoom 회의에 들어간 뒤 다시 시작해 주세요."
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
  /// 실사용 탭을 만들 때 실제로 포함한 Zoom 프로세스들이다. 실행 도중 이 대상이
  /// 모두 사라졌는지를 판정하는 데만 쓰며, A/B 진단 전에는 특정 프로세스가 최종
  /// 회의 오디오 경로라고 가정하지 않는다.
  private var capturedZoomProcesses: [AudioProcessInfo] = []

  private(set) var sourceFormat: AVAudioFormat?
  private(set) var captureScope: AudioCaptureScope?
  let captureHeartbeat: AudioCaptureHeartbeat
  private let onBuffer: (AVAudioPCMBuffer) -> Void

  init(captureHeartbeat: AudioCaptureHeartbeat = AudioCaptureHeartbeat(),
       onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
    self.captureHeartbeat = captureHeartbeat
    self.onBuffer = onBuffer
  }

  /// 값싼 시작 전 검사다. 일반 모드에서 Zoom 후보가 없다는 사실을 전사기와 Whisper를
  /// 준비하기 전에 알기 위한 것이며, 어느 process/device/stream이 최종 경로인지를
  /// 결정하지 않는다. 검사 직후 프로세스가 종료될 수 있으므로 `start(scope:)`도 같은
  /// 조건을 다시 확인해 TOCTOU 경쟁에서 전역 폴백이 생기지 않게 한다.
  static func validateSourceAvailability(for captureScope: AudioCaptureScope) throws {
    guard captureScope == .zoomMeetingOutput else { return }
    let hasZoomAudioCandidate = CoreAudioInfo.processes().contains {
      Self.zoomBundleIDs.contains($0.bundleID)
    }
    guard hasZoomAudioCandidate else { throw TapError.zoomAudioProcessUnavailable }
  }

  /// 명시된 범위만 캡처한다. Zoom 대상이 없을 때 시스템 전체 탭으로 넓히지 않고
  /// 즉시 실패해야 사용자가 Zoom 전용이라고 믿는 녹음에 다른 앱 소리가 섞이지 않는다.
  func start(scope requestedCaptureScope: AudioCaptureScope) throws {
    let availableAudioProcesses = CoreAudioInfo.processes()
    let zoomAudioProcessCandidates = availableAudioProcesses.filter {
      Self.zoomBundleIDs.contains($0.bundleID)
    }

    let captureTapDescription: CATapDescription
    switch requestedCaptureScope {
    case .zoomMeetingOutput:
      guard !zoomAudioProcessCandidates.isEmpty else {
        throw TapError.zoomAudioProcessUnavailable
      }
      captureTapDescription = CATapDescription(
        stereoMixdownOfProcesses: zoomAudioProcessCandidates.map(\.objectID))
      capturedZoomProcesses = zoomAudioProcessCandidates
    case .administratorSystemOutput:
      captureTapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
      capturedZoomProcesses = []
    }

    let uuid = UUID()
    captureTapDescription.name = "ZoomCaption"
    captureTapDescription.uuid = uuid
    captureTapDescription.isPrivate = true
    // 이 설정은 캡처 중에도 사용자가 원래 출력을 듣게 하는 동작일 뿐, 로컬
    // 마이크를 제외하는 필터가 아니다. 출처 분리는 관리자 A/B 결과 뒤에 결정한다.
    captureTapDescription.muteBehavior = .unmuted
    tapUUID = uuid

    var tap = AudioObjectID(kAudioObjectUnknown)
    let tapErr = AudioHardwareCreateProcessTap(captureTapDescription, &tap)
    guard tapErr == noErr else { throw TapError.tapCreationFailed(tapErr) }
    tapID = tap

    var fmtAddr = sysAddr(kAudioTapPropertyFormat)
    var asbd = AudioStreamBasicDescription()
    var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fsize, &asbd) == noErr,
          let fmt = AVAudioFormat(streamDescription: &asbd)
    else { throw TapError.formatUnavailable }
    sourceFormat = fmt

    guard let selectedOutputDeviceUID = CoreAudioInfo.defaultOutputUID() else {
      throw TapError.noOutputDevice
    }

    let aggregateDeviceDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "ZoomCaption Aggregate",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: selectedOutputDeviceUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[
        kAudioSubDeviceUIDKey: selectedOutputDeviceUID,
      ]],
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: uuid.uuidString,
      ]],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    let aggErr = AudioHardwareCreateAggregateDevice(
      aggregateDeviceDescription as CFDictionary, &agg)
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
    captureScope = requestedCaptureScope

    let processesIncludedInTap = requestedCaptureScope == .zoomMeetingOutput
      ? zoomAudioProcessCandidates
      : []
    let capturedProcessDescription = processesIncludedInTap.isEmpty
      ? "none"
      : processesIncludedInTap.map {
          "\($0.bundleID)(pid=\($0.pid),object=\($0.objectID))"
        }.joined(separator: ",")
    log("오디오 캡처 경로 — scope=\(requestedCaptureScope.rawValue), "
      + "processes=\(capturedProcessDescription), "
      + "defaultOutputUID=\(selectedOutputDeviceUID), "
      + "systemWideCapture=\(requestedCaptureScope == .administratorSystemOutput), "
      + "automaticGlobalFallback=false")
  }

  /// 시작 때 선택했던 Zoom 대상 중 하나라도 현재 남아 있는지 확인한다. 허용 목록에는
  /// 여러 보조 프로세스가 포함될 수 있어 하나가 종료됐다는 이유만으로 전체 경로를
  /// 잃었다고 판단하지 않고, 선택 대상이 모두 사라졌을 때만 false를 반환한다.
  var hasAvailableCapturedTarget: Bool {
    guard captureScope == .zoomMeetingOutput else { return true }
    let currentAudioProcessObjectIDs = Set(CoreAudioInfo.processes().map(\.objectID))
    return capturedZoomProcesses.contains {
      currentAudioProcessObjectIDs.contains($0.objectID)
    }
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

    // 샘플이 전부 0이어도 heartbeat는 갱신한다. 콘텐츠 무음은 공통 sink의
    // AudioActivityClock이 별도로 판정하므로 이 계층에서는 둘을 섞지 않는다.
    captureHeartbeat.recordAudioBufferArrival()
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
    tapUUID = nil
    captureScope = nil
    capturedZoomProcesses = []
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

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// 관리자 A/B 시험에서 캡처할 한 후보를 나타낸다.
///
/// `deviceUID`와 `streamIndex`가 둘 다 nil이면 프로세스 전체 출력을 측정한다. 둘 다
/// 있으면 그 프로세스가 지정 장치의 지정 출력 스트림으로 보내는 신호만 측정한다.
/// 운영 경로 모델과 의도적으로 분리해, 진단 결과가 나오기 전에 이 시그니처가 실제
/// Zoom 캡처 설계로 굳어지는 것을 막는다.
struct AdministratorAudioProbeSelection: Sendable {
  let process: AudioProcessInfo
  let deviceUID: String?
  let deviceName: String?
  let streamIndex: UInt?
  let streamObjectID: AudioStreamID?
}

/// 관리자 전용 Core Audio A/B 측정기다.
///
/// 전사기, TranscriptStore, AudioArchive에는 연결하지 않는다. 원본 PCM을 파일로도
/// 남기지 않고 콜백 수·피크·RMS·비무음 버퍼 비율만 집계하므로, 로컬 마이크 시험이
/// 실제 강의 기록이나 Whisper 결과를 오염시키지 않는다.
final class AdministratorAudioCaptureProbe: @unchecked Sendable {
  enum ProbeError: LocalizedError {
    case incompleteDeviceStreamSelection
    case noOutputDevice
    case tapCreationFailed(OSStatus)
    case formatUnavailable
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)

    var errorDescription: String? {
      switch self {
      case .incompleteDeviceStreamSelection:
        return "장치와 스트림 순번은 함께 지정해야 합니다."
      case .noOutputDevice:
        return "A/B probe가 사용할 출력 장치를 찾지 못했습니다."
      case .tapCreationFailed(let status):
        return "A/B 오디오 탭 생성 실패 (OSStatus \(status))"
      case .formatUnavailable:
        return "A/B 오디오 탭 포맷을 읽지 못했습니다."
      case .aggregateCreationFailed(let status):
        return "A/B 집합 장치 생성 실패 (OSStatus \(status))"
      case .ioProcFailed(let status):
        return "A/B 오디오 콜백 시작 실패 (OSStatus \(status))"
      }
    }
  }

  struct Snapshot: Sendable {
    let selection: AdministratorAudioProbeSelection
    let sourceFormatDescription: String
    let elapsedSeconds: TimeInterval
    let secondsSinceMostRecentBuffer: TimeInterval?
    let audioBufferCount: Int
    let observedFrameCount: Int64
    let peakDBFS: Double
    let rmsLevel: Double
    let nonSilentBufferRatio: Double
  }

  private let selection: AdministratorAudioProbeSelection
  private let statisticsLock = NSLock()
  private let probeStartedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  private var lastBufferArrivalUptimeNanoseconds: UInt64?
  private var audioBufferCount = 0
  private var nonSilentBufferCount = 0
  private var observedFrameCount: Int64 = 0
  private var maximumPeakLevel: Float = 0
  private var accumulatedSquaredSampleLevels = 0.0
  private var measuredSampleCount: Int64 = 0

  private var tapObjectID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceObjectID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceIOProcID: AudioDeviceIOProcID?
  private var tapUUID: UUID?
  private var sourceFormat: AVAudioFormat?

  init(selection: AdministratorAudioProbeSelection) {
    self.selection = selection
  }

  func start() throws {
    let hasDevice = selection.deviceUID != nil
    let hasStream = selection.streamIndex != nil
    guard hasDevice == hasStream else { throw ProbeError.incompleteDeviceStreamSelection }

    let tapDescription: CATapDescription
    if let selectedDeviceUID = selection.deviceUID,
       let selectedStreamIndex = selection.streamIndex {
      tapDescription = CATapDescription(
        processes: [selection.process.objectID],
        deviceUID: selectedDeviceUID,
        stream: selectedStreamIndex)
    } else {
      tapDescription = CATapDescription(
        stereoMixdownOfProcesses: [selection.process.objectID])
    }

    let newTapUUID = UUID()
    tapDescription.name = "ZoomCaption Administrator A-B Probe"
    tapDescription.uuid = newTapUUID
    tapDescription.isPrivate = true
    // probe는 사용자의 Zoom 청취를 바꾸면 안 된다. 이 값은 원래 출력을 유지할 뿐
    // 마이크를 제거하거나 오디오 샘플을 가공하지 않는다.
    tapDescription.muteBehavior = .unmuted
    tapUUID = newTapUUID

    var createdTapObjectID = AudioObjectID(kAudioObjectUnknown)
    let tapCreationStatus = AudioHardwareCreateProcessTap(
      tapDescription, &createdTapObjectID)
    guard tapCreationStatus == noErr else {
      throw ProbeError.tapCreationFailed(tapCreationStatus)
    }
    tapObjectID = createdTapObjectID

    var tapFormatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var streamDescription = AudioStreamBasicDescription()
    var streamDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(
      tapObjectID,
      &tapFormatAddress,
      0,
      nil,
      &streamDescriptionSize,
      &streamDescription) == noErr,
      let measuredSourceFormat = AVAudioFormat(streamDescription: &streamDescription)
    else { throw ProbeError.formatUnavailable }
    sourceFormat = measuredSourceFormat

    let aggregateOutputDeviceUID = selection.deviceUID ?? CoreAudioInfo.defaultOutputUID()
    guard let aggregateOutputDeviceUID else { throw ProbeError.noOutputDevice }
    let aggregateDeviceDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "ZoomCaption Administrator A-B Aggregate",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: aggregateOutputDeviceUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[
        kAudioSubDeviceUIDKey: aggregateOutputDeviceUID,
      ]],
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: newTapUUID.uuidString,
      ]],
    ]

    var createdAggregateDeviceObjectID = AudioObjectID(kAudioObjectUnknown)
    let aggregateCreationStatus = AudioHardwareCreateAggregateDevice(
      aggregateDeviceDescription as CFDictionary,
      &createdAggregateDeviceObjectID)
    guard aggregateCreationStatus == noErr else {
      throw ProbeError.aggregateCreationFailed(aggregateCreationStatus)
    }
    aggregateDeviceObjectID = createdAggregateDeviceObjectID

    var createdIOProcID: AudioDeviceIOProcID?
    let ioProcCreationStatus = AudioDeviceCreateIOProcIDWithBlock(
      &createdIOProcID,
      aggregateDeviceObjectID,
      nil
    ) { [weak self] _, inputAudioBufferList, _, _, _ in
      self?.observe(inputAudioBufferList)
    }
    guard ioProcCreationStatus == noErr, let createdIOProcID else {
      throw ProbeError.ioProcFailed(ioProcCreationStatus)
    }
    aggregateDeviceIOProcID = createdIOProcID

    let deviceStartStatus = AudioDeviceStart(
      aggregateDeviceObjectID, createdIOProcID)
    guard deviceStartStatus == noErr else {
      throw ProbeError.ioProcFailed(deviceStartStatus)
    }

    log("관리자 A/B probe 시작 — bundle=\(selection.process.bundleID), "
      + "pid=\(selection.process.pid), object=\(selection.process.objectID), "
      + "device=\(selection.deviceUID ?? "all"), "
      + "stream=\(selection.streamIndex.map(String.init) ?? "all")")
  }

  /// 버퍼를 저장하거나 변환하지 않고 통계만 계산한다. 모든 AudioBuffer를 순회해
  /// 비인터리브 다채널 포맷에서도 첫 채널만 보고 A/B 결과를 놓치지 않게 한다.
  private func observe(_ inputAudioBufferList: UnsafePointer<AudioBufferList>) {
    guard let sourceFormat else { return }
    let audioBuffers = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: inputAudioBufferList))

    var observedPeakLevel: Float = 0
    var squaredSampleLevelSum = 0.0
    var samplesMeasuredInThisBuffer: Int64 = 0

    for audioBuffer in audioBuffers {
      guard let rawAudioData = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
      switch sourceFormat.commonFormat {
      case .pcmFormatFloat32:
        let floatSampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let floatSamples = rawAudioData.assumingMemoryBound(to: Float.self)
        for sampleIndex in stride(from: 0, to: floatSampleCount, by: 4) {
          let absoluteSampleLevel = abs(floatSamples[sampleIndex])
          observedPeakLevel = max(observedPeakLevel, absoluteSampleLevel)
          squaredSampleLevelSum += Double(absoluteSampleLevel) * Double(absoluteSampleLevel)
          samplesMeasuredInThisBuffer += 1
        }
      case .pcmFormatInt16:
        let integerSampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
        let integerSamples = rawAudioData.assumingMemoryBound(to: Int16.self)
        for sampleIndex in stride(from: 0, to: integerSampleCount, by: 4) {
          let absoluteIntegerLevel = abs(Int(integerSamples[sampleIndex]))
          let normalizedSampleLevel = Float(absoluteIntegerLevel) / Float(Int16.max)
          observedPeakLevel = max(observedPeakLevel, normalizedSampleLevel)
          squaredSampleLevelSum += Double(normalizedSampleLevel) * Double(normalizedSampleLevel)
          samplesMeasuredInThisBuffer += 1
        }
      default:
        // 현재 Core Audio 탭은 Float32가 일반적이다. 알 수 없는 포맷에서도 콜백과
        // 프레임 수는 계속 기록하되 잘못 해석한 바이트로 피크를 만들지 않는다.
        break
      }
    }

    let bytesPerFrame = sourceFormat.streamDescription.pointee.mBytesPerFrame
    let firstBufferByteCount = audioBuffers.first?.mDataByteSize ?? 0
    let framesInThisCallback = bytesPerFrame > 0
      ? Int64(firstBufferByteCount / bytesPerFrame)
      : 0
    let containsNonSilentSample = observedPeakLevel > 1e-5
    let bufferArrivalUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

    statisticsLock.withLock {
      audioBufferCount += 1
      if containsNonSilentSample { nonSilentBufferCount += 1 }
      observedFrameCount += framesInThisCallback
      maximumPeakLevel = max(maximumPeakLevel, observedPeakLevel)
      accumulatedSquaredSampleLevels += squaredSampleLevelSum
      measuredSampleCount += samplesMeasuredInThisBuffer
      lastBufferArrivalUptimeNanoseconds = bufferArrivalUptimeNanoseconds
    }
  }

  func snapshot() -> Snapshot {
    let snapshotUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    return statisticsLock.withLock {
      let elapsedNanoseconds = snapshotUptimeNanoseconds >= probeStartedAtUptimeNanoseconds
        ? snapshotUptimeNanoseconds - probeStartedAtUptimeNanoseconds
        : 0
      let secondsSinceMostRecentBuffer = lastBufferArrivalUptimeNanoseconds.map {
        snapshotUptimeNanoseconds >= $0
          ? Double(snapshotUptimeNanoseconds - $0) / 1_000_000_000
          : 0
      }
      let measuredRMS = measuredSampleCount > 0
        ? (accumulatedSquaredSampleLevels / Double(measuredSampleCount)).squareRoot()
        : 0
      let measuredPeakDBFS = maximumPeakLevel > 0
        ? 20 * log10(Double(maximumPeakLevel))
        : -Double.infinity
      return Snapshot(
        selection: selection,
        sourceFormatDescription: sourceFormat.map {
          "\($0.sampleRate)Hz ch\($0.channelCount) \($0.commonFormat)"
        } ?? "-",
        elapsedSeconds: Double(elapsedNanoseconds) / 1_000_000_000,
        secondsSinceMostRecentBuffer: secondsSinceMostRecentBuffer,
        audioBufferCount: audioBufferCount,
        observedFrameCount: observedFrameCount,
        peakDBFS: measuredPeakDBFS,
        rmsLevel: measuredRMS,
        nonSilentBufferRatio: audioBufferCount > 0
          ? Double(nonSilentBufferCount) / Double(audioBufferCount)
          : 0)
    }
  }

  func stop() {
    if aggregateDeviceObjectID != AudioObjectID(kAudioObjectUnknown),
       let aggregateDeviceIOProcID {
      AudioDeviceStop(aggregateDeviceObjectID, aggregateDeviceIOProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceObjectID, aggregateDeviceIOProcID)
    }
    if aggregateDeviceObjectID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceObjectID)
    }
    if tapObjectID != AudioObjectID(kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(tapObjectID)
    }
    aggregateDeviceIOProcID = nil
    aggregateDeviceObjectID = AudioObjectID(kAudioObjectUnknown)
    tapObjectID = AudioObjectID(kAudioObjectUnknown)
    tapUUID = nil
    sourceFormat = nil
  }

  deinit { stop() }
}

/// HTTP 요청이 겹쳐 두 probe가 동시에 남지 않도록 현재 관리자 probe의 시작·조회·정지를
/// 한 락 아래 직렬화한다. probe 내부 통계 락과 분리되어 오디오 콜백은 이 락을 잡지 않는다.
final class AdministratorAudioCaptureProbeController: @unchecked Sendable {
  private let lock = NSLock()
  private var activeProbe: AdministratorAudioCaptureProbe?

  func start(
    selection: AdministratorAudioProbeSelection
  ) throws -> AdministratorAudioCaptureProbe.Snapshot {
    try lock.withLock {
      activeProbe?.stop()
      activeProbe = nil

      let newProbe = AdministratorAudioCaptureProbe(selection: selection)
      do {
        try newProbe.start()
        activeProbe = newProbe
        return newProbe.snapshot()
      } catch {
        newProbe.stop()
        throw error
      }
    }
  }

  func snapshot() -> AdministratorAudioCaptureProbe.Snapshot? {
    lock.withLock { activeProbe?.snapshot() }
  }

  func stop() -> AdministratorAudioCaptureProbe.Snapshot? {
    lock.withLock {
      guard let activeProbe else { return nil }
      let finalSnapshot = activeProbe.snapshot()
      activeProbe.stop()
      self.activeProbe = nil
      log("관리자 A/B probe 정지 — bundle=\(finalSnapshot.selection.process.bundleID), "
        + "buffers=\(finalSnapshot.audioBufferCount), "
        + "peak=\(String(format: "%.1f", finalSnapshot.peakDBFS))dBFS")
      return finalSnapshot
    }
  }
}

import Foundation
import Speech
import AVFoundation
import CoreMedia

enum TranscriptionError: LocalizedError {
  case unavailable
  case localeUnsupported(String)
  case formatUnavailable

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "이 기기에서 SpeechTranscriber를 쓸 수 없습니다."
    case .localeUnsupported(let id):
      return "\(id) 는 온디바이스 전사가 지원되지 않는 언어입니다."
    case .formatUnavailable:
      return "전사기가 요구하는 오디오 포맷을 확인할 수 없습니다."
    }
  }
}

/// 시스템 오디오에 대한 SpeechAnalyzer 파이프라인.
///
/// 이제 이쪽은 **화면에 지금 뜨는 자막** 만 담당한다. 정식 기록은 Whisper 가 만든다.
/// 그래서 신뢰도 속성은 받지 않는다 — 정확도를 따지는 자리가 아니고,
/// 속성을 늘릴수록 결과가 늦게 나온다.
final class TrackTranscriber: @unchecked Sendable {

  /// 결과에 붙어 오는 낱말별 시각을 본문 위치와 함께 뽑아낸다.
  ///
  /// `attributeOptions: [.audioTimeRange]` 로 이미 요청하고 있었는데, 여태 결과 **전체**의
  /// 범위만 쓰고 각 조각의 시각은 버렸다. 그래서 한 줄(중앙값 14.1초) 안에서는 시각 해상도가
  /// 아예 없었다.
  ///
  /// - Parameter trimmed: 저장될 최종 문자열. 앞뒤 공백을 떼었으므로 위치를 그쪽 기준으로 맞춘다.
  static let debugWordTimes = ProcessInfo.processInfo.environment["ZOOMCAPTION_DEBUG_WORDS"] == "1"

  /// 애플 VAD 감도. 설정이 없으면 붙이지 않는다(지금까지의 동작 그대로).
  static var detectorSensitivity: SpeechDetector.SensitivityLevel? {
    switch ProcessInfo.processInfo.environment["ZOOMCAPTION_VAD_SENSITIVITY"] {
    case "low":    return .low
    case "medium": return .medium
    case "high":   return .high
    default:       return nil
    }
  }

  static func wordTimes(_ attributed: AttributedString, trimmed: String) -> [WordTime] {
    // 원본에서 잘려 나간 앞 공백만큼 위치를 당겨 준다.
    let full = String(attributed.characters)
    let lead = full.distance(from: full.startIndex,
                             to: full.range(of: trimmed)?.lowerBound ?? full.startIndex)
    var out: [WordTime] = []
    var cursor = 0
    if Self.debugWordTimes {
      let runs = attributed.runs.map {
        "「\(String(attributed[$0.range].characters))」"
        + ($0.audioTimeRange.map { r in "@\(String(format: "%.2f", r.start.seconds))" } ?? "@none")
      }
      log("낱말시각 진단 — run \(runs.count)개: \(runs.prefix(8).joined(separator: " "))")
    }
    for run in attributed.runs {
      let piece = String(attributed[run.range].characters)
      defer { cursor += piece.count }
      guard let range = run.audioTimeRange else { continue }
      let offset = cursor - lead
      guard offset >= 0, offset + piece.count <= trimmed.count else { continue }
      // 공백뿐인 조각은 자리만 차지한다.
      guard piece.contains(where: { !$0.isWhitespace }) else { continue }
      out.append(WordTime(offset: offset, length: piece.count,
                          start: range.start.seconds, end: range.end.seconds))
    }
    return out
  }
  /// 빠른 결과 보고. 기본 켜짐 — 끄면 첫 자막까지 10초를 기다린다.
  static var fastResultsEnabled: Bool {
    ProcessInfo.processInfo.environment["ZOOMCAPTION_FAST_RESULTS"] != "0"
  }

  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var resampler: AudioResampler?
  private var pumpTask: Task<Void, Never>?

  /// 언어 모델 자산을 확인하고 필요하면 내려받는다. 앱 시작 시 한 번만 호출하면 된다.
  static func prepareAssets(locale requested: Locale,
                            onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Locale {
    guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
      throw TranscriptionError.localeUnsupported(requested.identifier)
    }

    let probe = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    if await AssetInventory.status(forModules: [probe]) != .installed,
       let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
      let progress = request.progress
      let watcher = Task {
        while !Task.isCancelled && !progress.isFinished {
          onProgress?(progress.fractionCompleted)
          try? await Task.sleep(for: .milliseconds(400))
        }
      }
      defer { watcher.cancel() }
      try await request.downloadAndInstall()
      onProgress?(1.0)
    }

    // 예약해두면 모델이 메모리에 유지되어 첫 인식 지연이 줄어든다.
    _ = try? await AssetInventory.reserve(locale: locale)
    return locale
  }

  /// 전사기가 원하는 입력 오디오 포맷 (보통 16kHz mono Int16)
  static func analyzerFormat(locale: Locale) async throws -> AVAudioFormat {
    let probe = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
      throw TranscriptionError.formatUnavailable
    }
    return fmt
  }

  func start(locale: Locale,
             audioFormat: AVAudioFormat,
             contextualStrings: [String],
             onFinal: @escaping @Sendable (Double, Double, String, [WordTime]) -> Void,
             onVolatile: @escaping @Sendable (String) -> Void) async throws {
    // .fastResults 를 빼면 첫 자막이 나오기까지 10초를 기다린다(실측, 매우 일정).
    // 수업 자막은 지금 화면에 떠야 쓸모가 있어서 지연을 기본값으로 우선한다.
    // 정확도를 더 원하면 ZOOMCAPTION_FAST_RESULTS=0 으로 끌 수 있다.
    var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    if Self.fastResultsEnabled { reporting.insert(.fastResults) }
    let t = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: reporting,
      attributeOptions: [.audioTimeRange])
    transcriber = t
    resampler = AudioResampler(target: audioFormat)

    let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
    continuation = cont

    // 애플 VAD. **기본은 안 붙인다** — 지금까지 아무 설정 없이 돌았고,
    // 실시간 전사기는 침묵을 침묵으로 두므로 고칠 문제가 없었다.
    // 붙이면 무엇이 달라지는지(특히 영문 인식률) 재보려고 열어 둔 손잡이다.
    // `ZOOMCAPTION_VAD_SENSITIVITY=low|medium|high`
    var modules: [any SpeechModule] = [t]
    if let level = Self.detectorSensitivity {
      modules.append(SpeechDetector(detectionOptions: .init(sensitivityLevel: level),
                                    reportResults: false))
      log("애플 VAD 붙임 — 감도 \(ProcessInfo.processInfo.environment["ZOOMCAPTION_VAD_SENSITIVITY"] ?? "?")")
    }
    let a = SpeechAnalyzer(modules: modules,
                           options: .init(priority: .userInitiated, modelRetention: .whileInUse))
    analyzer = a

    if !contextualStrings.isEmpty {
      let ctx = AnalysisContext()
      ctx.contextualStrings = [.general: contextualStrings]
      try? await a.setContext(ctx)
    }

    try await a.prepareToAnalyze(in: audioFormat)

    pumpTask = Task {
      do {
        for try await result in t.results {
          let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { continue }
          if result.isFinal {
            onFinal(result.range.start.seconds, result.range.end.seconds, text,
                    Self.wordTimes(result.text, trimmed: text))
          } else {
            onVolatile(text)
          }
        }
      } catch {
        logWarn("전사 스트림 종료: \(error.localizedDescription)")
      }
    }

    try await a.start(inputSequence: stream)
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard let resampler, let continuation,
          let converted = resampler.convert(buffer) else { return }
    continuation.yield(AnalyzerInput(buffer: converted))
  }

  func finish() async {
    continuation?.finish()
    continuation = nil
    try? await analyzer?.finalizeAndFinishThroughEndOfInput()

    // 마지막 확정 결과는 results 스트림을 통해 별도 태스크로 전달된다.
    // 여기서 바로 cancel 하면 정지 직전에 말한 문장이 통째로 사라진다.
    // 스트림이 자연스럽게 끝날 때까지 기다리되, 매달리지 않도록 상한을 둔다.
    if let pumpTask {
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await pumpTask.value }
        group.addTask { try? await Task.sleep(for: .seconds(5)) }
        await group.next()
        group.cancelAll()
      }
    }

    pumpTask?.cancel()
    pumpTask = nil
    analyzer = nil
    transcriber = nil
    resampler = nil
  }
}

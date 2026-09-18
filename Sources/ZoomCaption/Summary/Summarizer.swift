import Foundation

/// 사용자 화면에 표시할 현재 요약 엔진 상태. 자동 폴백은 없다.
enum SummaryEngine: Sendable, Equatable {
  case ollama(String)
  case unavailable(String)

  var label: String {
    switch self {
    case .ollama(let model): return "Ollama · \(model)"
    case .unavailable: return "Qwen/Ollama · 사용 불가"
    }
  }

  var note: String? {
    guard case .unavailable(let reason) = self else { return nil }
    return reason
  }
}

/// Whisper의 구조화된 시간·경계를 보존하면서 Qwen으로 시간대별 요약을 만든다.
enum Summarizer {
  enum SummarizerError: LocalizedError {
    case emptyTranscript
    case noQwenModel
    case serverUnavailable
    case noLectureUnit

    var errorDescription: String? {
      switch self {
      case .emptyTranscript:
        return "Whisper 전사가 아직 준비되지 않았거나 요약할 내용이 없습니다."
      case .noQwenModel:
        return "쓸 수 있는 Qwen 모델이 없습니다. `ollama pull qwen3:8b`로 내려받으세요."
      case .serverUnavailable:
        return "Ollama 서버를 시작하지 못했습니다. 설치 상태와 실행 권한을 확인하세요."
      case .noLectureUnit:
        return "강의 경계에서 요약할 시간대를 만들지 못했습니다."
      }
    }
  }

  /// 서버가 꺼져 있어도 디스크에 Qwen 모델이 있으면 사용 가능으로 표시한다.
  static func currentEngine() async -> SummaryEngine {
    if let installed = await OllamaClient.installedModels(),
       let model = OllamaClient.pickSummaryModel(from: installed) {
      return .ollama(model)
    }
    if OllamaClient.binaryPath != nil,
       let model = OllamaClient.pickSummaryModel(from: OllamaClient.installedModelsOffline()) {
      return .ollama(model)
    }
    return .unavailable("Ollama와 Qwen 모델이 필요합니다. Apple 모델로 자동 전환하지 않습니다.")
  }

  /// - Parameter onProgress: 완료된 모델 호출 수와 전체 모델 호출 수.
  static func summarize(units: [LectureUnit],
                        title: String,
                        glossary: String = "",
                        onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> String {
    guard units.contains(where: { !$0.segments.isEmpty }) else {
      throw SummarizerError.emptyTranscript
    }
    guard case .ollama(let model) = await currentEngine() else {
      throw SummarizerError.noQwenModel
    }
    guard await OllamaClient.ensureServer() else { throw SummarizerError.serverUnavailable }

    let glossaryTokens = Int(Double(glossary.count) * OllamaClient.tokensPerChar)
    let transcriptBudget = max(4_000,
      SummaryChunker.defaultTranscriptTokenBudget - min(20_000, glossaryTokens))
    let chunksByUnit = units.map {
      SummaryChunker.makeChunks(for: $0, tokenBudget: transcriptBudget)
    }
    let unitCalls = chunksByUnit.reduce(0) { partial, chunks in
      partial + chunks.count + (chunks.count > 1 ? 1 : 0)
    }
    let totalCalls = unitCalls + 1
    var completedCalls = 0
    onProgress(0, totalCalls)

    let client = OllamaQwenSummaryClient(modelName: model)
    log("Qwen 시간대별 요약 시작 — \(units.count)개 시간대, \(chunksByUnit.flatMap { $0 }.count)개 내부 청크, 입력 예산 \(transcriptBudget)토큰")

    do {
      var entries: [LectureSummaryDocument.Entry] = []
      for (unitOffset, unit) in units.enumerated() {
        let chunks = chunksByUnit[unitOffset]
        var partSummaries: [UnitSummary] = []

        for chunk in chunks {
          let request = UnitSummaryRequest(
            lectureTitle: title,
            unitId: unit.id,
            unitCount: units.count,
            partIndex: chunk.partIndex,
            partCount: chunk.partCount,
            start: chunk.start,
            end: chunk.end,
            transcript: chunk.transcript,
            glossary: glossary)
          var part = try await client.summarizeUnit(request)
          part.unitId = unit.id
          partSummaries.append(part)
          completedCalls += 1
          onProgress(completedCalls, totalCalls)
        }

        let summary: UnitSummary
        if partSummaries.count == 1, let only = partSummaries.first {
          summary = only
        } else {
          var merged = try await client.mergeUnitParts(
            UnitMergeRequest(lectureTitle: title, unitId: unit.id, parts: partSummaries))
          merged.unitId = unit.id
          summary = merged
          completedCalls += 1
          onProgress(completedCalls, totalCalls)
        }
        entries.append(.init(unit: unit, summary: summary))
      }

      let overview = try await client.summarizeOverview(
        OverviewRequest(lectureTitle: title, units: entries.map(\.summary)))
      completedCalls += 1
      onProgress(completedCalls, totalCalls)
      let result = SummaryRenderer.render(.init(overview: overview, units: entries))
      await client.unload()
      log("Qwen 시간대별 요약 완료 — \(units.count)개 시간대, 모델 호출 \(completedCalls)회")
      return result
    } catch {
      await client.unload()
      throw error
    }
  }
}

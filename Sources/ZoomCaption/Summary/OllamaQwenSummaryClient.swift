import Foundation

struct OllamaQwenSummaryClient: SummaryModelClient {
  let modelName: String
  let contextLimit = OllamaClient.maxContext

  func summarizeUnit(_ request: UnitSummaryRequest) async throws -> UnitSummary {
    let parsed = try await chatJSON(system: SummaryPrompts.unitSystem,
                                    user: SummaryPrompts.unitUser(request),
                                    schema: SummaryPrompts.unitSchema,
                                    outputReserve: 4_096,
                                    keepAlive: "10m",
                                    operation: "시간대 \(request.unitId) 요약")
    return try parseUnitSummary(parsed, expectedUnitId: request.unitId)
  }

  func mergeUnitParts(_ request: UnitMergeRequest) async throws -> UnitSummary {
    let parsed = try await chatJSON(system: SummaryPrompts.mergeSystem,
                                    user: try SummaryPrompts.mergeUser(request),
                                    schema: SummaryPrompts.unitSchema,
                                    outputReserve: 4_096,
                                    keepAlive: "10m",
                                    operation: "시간대 \(request.unitId) 병합")
    return try parseUnitSummary(parsed, expectedUnitId: request.unitId)
  }

  func summarizeOverview(_ request: OverviewRequest) async throws -> String {
    let parsed = try await chatJSON(system: SummaryPrompts.overviewSystem,
                                    user: try SummaryPrompts.overviewUser(request),
                                    schema: SummaryPrompts.overviewSchema,
                                    outputReserve: 1_024,
                                    keepAlive: 0,
                                    operation: "전체 개요")
    guard let overview = parsed["overview"] as? String else {
      throw OllamaClient.OllamaError.badResponse("전체 개요 필드가 없습니다.")
    }
    return overview.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func unload() async {
    guard let url = URL(string: "\(OllamaClient.host)/api/generate") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "model": modelName, "keep_alive": 0,
    ])
    request.timeoutInterval = 10
    _ = try? await URLSession.shared.data(for: request)
  }

  private func parseUnitSummary(_ parsed: [String: Any], expectedUnitId: Int) throws -> UnitSummary {
    let insights: [SummaryInsight] = (parsed["keyInsights"] as? [[String: Any]] ?? [])
      .prefix(5).compactMap { item -> SummaryInsight? in
      guard let point = item["point"] as? String,
            let explanation = item["explanation"] as? String else { return nil }
      return SummaryInsight(point: point, explanation: explanation)
    }
    let terms: [SummaryTerm] = (parsed["terms"] as? [[String: Any]] ?? [])
      .prefix(6).compactMap { item -> SummaryTerm? in
      guard let term = item["term"] as? String,
            let meaning = item["meaning"] as? String else { return nil }
      return SummaryTerm(term: term, meaning: meaning)
    }
    guard let title = parsed["title"] as? String,
          let summary = parsed["summary"] as? String else {
      throw OllamaClient.OllamaError.badResponse("시간대 요약의 필수 필드가 없습니다.")
    }
    return UnitSummary(unitId: expectedUnitId,
                       title: title,
                       summary: summary,
                       keyInsights: Array(insights),
                       terms: Array(terms))
  }

  private func chatJSON(system: String,
                        user: String,
                        schema: [String: Any],
                        outputReserve: Int,
                        keepAlive: Any,
                        operation: String) async throws -> [String: Any] {
    let promptTokens = Int(Double(system.count + user.count) * OllamaClient.tokensPerChar)
    let estimatedTotal = promptTokens + outputReserve
    guard estimatedTotal <= contextLimit else {
      throw OllamaClient.OllamaError.contextExceeded(
        estimatedTokens: estimatedTotal, limit: contextLimit)
    }
    let numContext = min(contextLimit, max(8_192, estimatedTotal + 512))
    let body: [String: Any] = [
      "model": modelName,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "stream": false,
      "format": schema,
      "think": false,
      "keep_alive": keepAlive,
      "options": ["temperature": 0, "num_ctx": numContext],
    ]

    guard let url = URL(string: "\(OllamaClient.host)/api/chat") else {
      throw OllamaClient.OllamaError.notRunning
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 900

    log("Ollama \(operation) 요청 — 모델 \(modelName), 프롬프트 추정 \(promptTokens)토큰, num_ctx \(numContext)")
    let startedAt = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw OllamaClient.OllamaError.badResponse(
        String(data: data.prefix(300), encoding: .utf8) ?? "?")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = root["message"] as? [String: Any],
          let content = message["content"] as? String,
          let parsed = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    else {
      throw OllamaClient.OllamaError.badResponse(
        String(data: data.prefix(300), encoding: .utf8) ?? "?")
    }
    let actualPrompt = root["prompt_eval_count"] as? Int
    let actualOutput = root["eval_count"] as? Int
    log("Ollama \(operation) 완료 — \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))초"
      + " · 실제 입력 \(actualPrompt.map(String.init) ?? "?")토큰"
      + " · 출력 \(actualOutput.map(String.init) ?? "?")토큰")
    return parsed
  }
}

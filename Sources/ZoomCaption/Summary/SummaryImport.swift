import Foundation

/// 사용자가 온라인 LLM에서 복사해 온 마크다운을 검증·정규화한다.
enum SummaryImport {
  struct Result: Sendable {
    let markdown: String
    /// 저장은 하되 사용자에게 알려야 하는 문제. nil이면 깨끗하다.
    let warning: String?
    /// 마지막 구간 헤딩이 말하는 실제 요약 끝이다. 전체 전사 끝을 대신 쓰면 부분
    /// 요약 뒤의 “이어서”가 세션 끝으로 건너뛰므로 문서 자체를 최우선 근거로 삼는다.
    let lastUnitEnd: Double?
    /// 서버 로그에는 본문을 남기지 않고도 모델이 몇 구간을 돌려줬는지 기록해야
    /// 하므로, 이미 검증하면서 센 헤딩 수만 함께 돌려준다.
    let unitCount: Int
  }

  enum ImportError: LocalizedError {
    case empty
    case notASummary
    case exportedPrompt

    var errorDescription: String? {
      switch self {
      case .empty:
        "붙여넣은 요약이 비어 있습니다."
      case .notASummary:
        "전체 개요가 없어 ZoomCaption 요약으로 확인할 수 없습니다."
      case .exportedPrompt:
        "이건 요약이 아니라 내보낸 프롬프트입니다. 온라인 LLM이 만든 답변을 넣어 주세요."
      }
    }
  }

  static func validate(_ rawMarkdown: String, expectedUnitCount: Int) throws -> Result {
    var markdown = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    markdown = stripWholeCodeFence(from: markdown)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    markdown = discardPreamble(from: markdown)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !markdown.isEmpty else { throw ImportError.empty }

    // 내보낸 프롬프트는 출력 템플릿을 그대로 품고 있어 개요 헤딩 검사만으로는 요약과
    // 구분되지 않는다. 사용자가 받은 프롬프트 .md를 실수로 끌어다 놓으면 멀쩡한 요약이
    // 프롬프트 전문으로 덮여 사라지므로, 요약에는 절대 없는 표식을 먼저 걸러낸다.
    // 브라우저 쪽 동일성 비교는 클립보드 경로만 막아 파일 드롭·수동 붙여넣기에는
    // 닿지 않는다. 따라서 이 판정은 반드시 서버에 있어야 한다.
    guard !looksLikeExportedPrompt(markdown) else { throw ImportError.exportedPrompt }

    // 무관한 클립보드 텍스트를 요약으로 덮어쓰지 않게 하는 핵심 방어선이다. 제목은
    // 모델마다 빠뜨릴 수 있어도 전체 개요 헤딩까지 없는 문서는 받아들이지 않는다.
    guard containsOverviewHeading(markdown) else { throw ImportError.notASummary }

    var warnings: [String] = []
    let foundUnitCount = countUnitHeadings(in: markdown) ?? 0
    if expectedUnitCount > 0, foundUnitCount != expectedUnitCount {
      // 모델이 구간을 합쳤어도 내용은 복습에 쓸 수 있으므로 버리지는 않는다. 재시도할지
      // 불완전한 결과를 쓸지는 원문을 볼 수 있는 사용자가 판단하도록 경고만 돌려준다.
      warnings.append("기대 \(expectedUnitCount)구간 / 수신 \(foundUnitCount)구간 — 일부 구간이 누락됐을 수 있습니다.")
    }
    let lastUnitEnd = parseLastUnitEnd(in: markdown)
    if lastUnitEnd == nil {
      // 조용히 전체 끝으로 폴백하면 부분 요약 뒤의 이어서 지점이 또 틀려도 사용자가
      // 알아차릴 수 없다. 저장은 허용하되 정확도가 떨어졌다는 사실은 반드시 보인다.
      warnings.append("요약 범위를 읽지 못해 \"이어서\" 지점이 부정확할 수 있습니다.")
    }
    return Result(markdown: markdown,
                  warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
                  lastUnitEnd: lastUnitEnd,
                  unitCount: foundUnitCount)
  }

  /// 전체 문서를 감싼 코드펜스만 벗긴다. 본문 안의 예제 펜스까지 지우면 강의 내용이
  /// 변하므로 여는 줄과 마지막 줄의 백틱 개수가 같은 경우에만 처리한다.
  private static func stripWholeCodeFence(from markdown: String) -> String {
    let lines = markdown.components(separatedBy: .newlines)
    guard lines.count >= 3 else { return markdown }
    let opening = lines[0].trimmingCharacters(in: .whitespaces)
    let closing = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
    let backtickCount = opening.prefix(while: { $0 == "`" }).count
    guard backtickCount >= 3,
          closing == String(repeating: "`", count: backtickCount) else { return markdown }
    let language = opening.dropFirst(backtickCount).trimmingCharacters(in: .whitespaces)
    guard language.isEmpty || language.lowercased() == "markdown" || language.lowercased() == "md"
    else { return markdown }
    return lines.dropFirst().dropLast().joined(separator: "\n")
  }

  /// 정규식 컴파일 실패는 입력 거부 사유가 아니다. 헤딩을 못 찾으면 원문을 그대로
  /// 두고 다음의 필수 개요 검사에서 보수적으로 판단한다.
  private static func discardPreamble(from markdown: String) -> String {
    let pattern = #"(?m)^# 전체 강의 요약[ \t]*$|^## 전체 개요[ \t]*$"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
          let headingRange = Range(match.range, in: markdown) else { return markdown }
    return String(markdown[headingRange.lowerBound...])
  }

  /// `PromptExport`가 만드는 프롬프트에만 있고 완성된 요약에는 나올 수 없는 표식이다.
  /// 녹취 원문을 감싸는 태그와 지시문 머리말을 함께 봐서, 강의에서 우연히 같은 낱말이
  /// 언급된 요약을 프롬프트로 오인하지 않는다.
  private static func looksLikeExportedPrompt(_ markdown: String) -> Bool {
    markdown.contains("<transcript>") || markdown.contains("[구간 경계]")
      || markdown.contains("[출력 형식]")
  }

  private static func containsOverviewHeading(_ markdown: String) -> Bool {
    let pattern = #"(?m)^##[ \t]+전체[ \t]+개요[ \t]*$"#
    // 정규식 엔진이 패턴을 만들지 못한 드문 환경에서도 명백한 표준 헤딩까지 거부해
    // 가져오기 전체를 막지는 않는다. 평소에는 줄 단위 정규식이 더 엄격한 방어선이다.
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return markdown.contains("## 전체 개요")
    }
    return expression.firstMatch(
      in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) != nil
  }

  private static func countUnitHeadings(in markdown: String) -> Int? {
    let pattern = #"(?m)^## (\d+)강 · "#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    return expression.numberOfMatches(
      in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
  }

  /// 마지막 구간 헤딩의 끝 시각만 읽는다. 온라인 모델이 한 시간 미만 시각을 MM:SS로
  /// 줄이는 경우가 있어 HH:MM:SS와 MM:SS를 모두 허용하되, 일반 본문 속 시각은
  /// 이어서 기준으로 오인하지 않도록 구간 헤딩 줄에서만 찾는다.
  private static func parseLastUnitEnd(in markdown: String) -> Double? {
    let pattern = #"(?m)^##[ \t]+\d+강[ \t]*·[ \t]*(?:\d+:)?\d{1,2}:\d{2}[ \t]*~[ \t]*((?:\d+:)?\d{1,2}:\d{2})[ \t]*$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let matches = expression.matches(
      in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
    guard let match = matches.last,
          let timeRange = Range(match.range(at: 1), in: markdown) else { return nil }
    let components = markdown[timeRange].split(separator: ":").compactMap { Double($0) }
    guard components.count == 2 || components.count == 3 else { return nil }
    if components.count == 2 {
      return components[0] * 60 + components[1]
    }
    return components[0] * 3600 + components[1] * 60 + components[2]
  }
}

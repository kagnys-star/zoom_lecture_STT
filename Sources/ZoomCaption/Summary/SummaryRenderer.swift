import Foundation

enum SummaryRenderer {
  static func render(_ document: LectureSummaryDocument) -> String {
    var output = "# 전체 강의 요약\n\n"
    let overview = clean(document.overview)
    output += "## 전체 개요\n\n"
    output += overview.isEmpty ? "요약할 핵심 내용이 없습니다." : overview
    output += "\n\n"

    for entry in document.units {
      let unit = entry.unit
      let summary = entry.summary
      output += "## \(unit.id)강 · \(TranscriptStore.clock(unit.start))~\(TranscriptStore.clock(unit.end))\n\n"

      let title = clean(summary.title)
      if !title.isEmpty { output += "**\(title)**\n\n" }

      output += "### 구간 요약\n\n"
      let body = clean(summary.summary)
      output += body.isEmpty ? "요약할 핵심 내용이 없습니다." : body
      output += "\n\n### 핵심\n\n"

      let insights = summary.keyInsights.compactMap { insight -> SummaryInsight? in
        let point = clean(insight.point)
        let explanation = clean(insight.explanation)
        guard !point.isEmpty, !explanation.isEmpty else { return nil }
        return SummaryInsight(point: point, explanation: explanation)
      }
      if insights.isEmpty {
        output += "추출된 핵심이 없습니다.\n\n"
      } else {
        output += insights.map { "- **\($0.point)** \($0.explanation)" }.joined(separator: "\n")
        output += "\n\n"
      }

      let terms = deduplicateTerms(summary.terms)
      if !terms.isEmpty {
        output += "### 핵심 용어\n\n"
        output += terms.map { "- **\($0.term)** — \($0.meaning)" }.joined(separator: "\n")
        output += "\n\n"
      }
    }
    return output
  }

  /// 정보 손실을 피하기 위해 정규화한 이름이 완전히 같은 경우만 제거한다.
  static func deduplicateTerms(_ terms: [SummaryTerm]) -> [SummaryTerm] {
    var seen = Set<String>()
    var output: [SummaryTerm] = []
    for term in terms {
      let name = clean(term.term)
      let meaning = clean(term.meaning)
      let key = normalizedName(name)
      guard !key.isEmpty, !meaning.isEmpty, seen.insert(key).inserted else { continue }
      output.append(SummaryTerm(term: name, meaning: meaning))
    }
    return output
  }

  private static func normalizedName(_ text: String) -> String {
    text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
  }

  private static func clean(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

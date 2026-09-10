import Foundation

enum SummaryChunker {
  static let defaultTranscriptTokenBudget = 24_000

  /// `boundaryAfter`만 상위 강의 단위를 닫는다. paragraph는 여기서 보지 않는다.
  static func makeUnits(from segments: [SummaryInputSegment]) -> [LectureUnit] {
    let ordered = segments
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    guard !ordered.isEmpty else { return [] }

    var units: [LectureUnit] = []
    var pending: [SummaryInputSegment] = []

    func appendPending() {
      guard let first = pending.first, let last = pending.last else { return }
      units.append(LectureUnit(id: units.count + 1,
                               start: first.start,
                               end: last.end,
                               segments: pending))
      pending.removeAll(keepingCapacity: true)
    }

    for segment in ordered {
      pending.append(segment)
      if segment.boundaryAfter != nil { appendPending() }
    }
    appendPending()
    return units
  }

  static func makeChunks(for unit: LectureUnit,
                         tokenBudget: Int = defaultTranscriptTokenBudget,
                         tokensPerCharacter: Double = OllamaClient.tokensPerChar) -> [LectureUnitChunk] {
    guard tokenBudget > 0, !unit.segments.isEmpty else { return [] }
    let characterBudget = max(1, Int(Double(tokenBudget) / tokensPerCharacter))
    let expanded = unit.segments.flatMap { splitOversized($0, characterBudget: characterBudget) }

    var ranges: [Range<Int>] = []
    var start = 0
    while start < expanded.count {
      var end = start
      var characters = 0
      while end < expanded.count {
        let next = formatted(expanded[end]).count + (end == start ? 0 : 1)
        if end > start, characters + next > characterBudget { break }
        characters += next
        end += 1
        if characters >= characterBudget { break }
      }
      if end == expanded.count {
        ranges.append(start..<end)
        break
      }

      // 용량의 절반 이후에 있는 가장 가까운 paragraph 경계를 우선 사용한다.
      // paragraph 번호 자체는 강의 경계가 아니므로, 오직 과대 단위 내부에서만 본다.
      let minimumUsefulEnd = start + max(1, (end - start) / 2)
      var paragraphEnd: Int?
      if end - start > 1 {
        for candidate in stride(from: end - 1, through: minimumUsefulEnd, by: -1) {
          let before = expanded[candidate - 1].paragraph
          let after = expanded[candidate].paragraph
          if before != nil, after != nil, before != after {
            paragraphEnd = candidate
            break
          }
        }
      }
      let chosenEnd = max(start + 1, paragraphEnd ?? end)
      ranges.append(start..<chosenEnd)
      start = chosenEnd
    }

    return ranges.enumerated().map { offset, range in
      let slice = Array(expanded[range])
      return LectureUnitChunk(
        unitId: unit.id,
        partIndex: offset + 1,
        partCount: ranges.count,
        start: slice.first?.start ?? unit.start,
        end: slice.last?.end ?? unit.end,
        transcript: slice.map(formatted).joined(separator: "\n"))
    }
  }

  private static func formatted(_ segment: SummaryInputSegment) -> String {
    "[\(TranscriptStore.clock(segment.start))] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  /// 정상적인 Whisper 문장은 이 경로에 오지 않는다. 한 세그먼트 자체가 예산을
  /// 넘는 비정상 입력만 문장부호·공백에 가까운 지점에서 잘라 모든 글자를 보존한다.
  private static func splitOversized(_ segment: SummaryInputSegment,
                                     characterBudget: Int) -> [SummaryInputSegment] {
    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixReserve = 16
    let limit = max(1, characterBudget - prefixReserve)
    guard text.count > limit else { return [segment] }

    var fragments: [String] = []
    var rest = text[...]
    while rest.count > limit {
      let hardEnd = rest.index(rest.startIndex, offsetBy: limit)
      let searchStart = rest.index(rest.startIndex, offsetBy: max(1, limit / 2))
      let window = rest[searchStart..<hardEnd]
      let punctuation = window.lastIndex(where: { ".!?。！？\n".contains($0) })
      let whitespace = window.lastIndex(where: { $0.isWhitespace })
      let cut = punctuation.map { rest.index(after: $0) } ?? whitespace ?? hardEnd
      fragments.append(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
      rest = rest[cut...].drop(while: { $0.isWhitespace })
    }
    if !rest.isEmpty { fragments.append(String(rest)) }

    return fragments.enumerated().map { index, fragment in
      SummaryInputSegment(id: segment.id,
                          start: segment.start,
                          end: segment.end,
                          text: fragment,
                          paragraph: segment.paragraph.map { $0 + index },
                          boundaryAfter: index == fragments.count - 1 ? segment.boundaryAfter : nil)
    }
  }
}

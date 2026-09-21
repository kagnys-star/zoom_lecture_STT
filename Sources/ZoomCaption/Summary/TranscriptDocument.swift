import Foundation

/// 온라인 요약 프롬프트에 넣을 전사 본문을 만든다.
///
/// 왜 시각을 빼는가 — 줄머리의 `[00:12:34] `(11자)는 요약 경로 어디서도 쓰이지 않는다.
/// 구간을 나누는 것은 `Segment.boundaryAfter` 뿐이고(`SummaryChunker.makeUnits`),
/// 프롬프트의 구간 목록과 출력 템플릿 헤딩의 시각은 서버가 계산해 따로 박아 넣는
/// 값이며, 돌아온 요약에서 "이어서" 지점을 읽는 `SummaryImport.parseLastUnitEnd`도
/// 구간 헤딩만 본다. 즉 줄마다 붙던 시각은 전부 중복이었고, Whisper 한 줄이 40자
/// 안팎이라 본문의 약 5분의 1을 차지하고 있었다.
enum TranscriptDocument {
  /// 녹취 본문만 만든다. 프롬프트의 `<transcript>` 안에 그대로 들어간다.
  static func render(units: [LectureUnit]) -> String {
    var lines: [String] = []
    for unit in units {
      if !lines.isEmpty { lines.append("") }
      lines.append(unitHeader(for: unit))
      for segment in unit.segments {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        lines.append(text)
        if let boundaryLabel = TranscriptStore.markdownLabel(for: segment.boundaryAfter) {
          // 저장 Markdown·프롬프트와 같은 라벨 함수를 거쳐야 경계 종류가 늘어도 한쪽만
          // 예전 문구를 쓰거나 경계를 빠뜨리는 일이 생기지 않는다.
          lines.append("> **\(boundaryLabel)**")
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  /// `=== 2강 · 00:10:00~00:20:00 ===` 형태. 마크다운 헤딩(`##`)을 쓰지 않는 이유는 요약 출력 템플릿이
  /// 같은 문법의 `## N강 · ...` 헤딩을 쓰기 때문이다. 녹취 안에 같은 모양이 있으면
  /// 모델이 그것을 답의 일부로 베끼고, 돌아온 문서의 구간 수를 세는 검사도 흔들린다.
  static func unitHeader(for unit: LectureUnit) -> String {
    return "=== \(unit.id)강 · \(TranscriptStore.clock(unit.start))"
      + "~\(TranscriptStore.clock(unit.end)) ==="
  }
}

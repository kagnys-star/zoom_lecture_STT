import Foundation

/// 시각이 없는 전사 문서를 만들고, 밖에서 고쳐져 돌아온 같은 문서를 읽는다.
///
/// 왜 시각을 빼는가 — 줄머리의 `[00:12:34] `(11자)는 요약 경로 어디서도 쓰이지 않는다.
/// 구간을 나누는 것은 `Segment.boundaryAfter` 뿐이고(`SummaryChunker.makeUnits`),
/// 프롬프트의 구간 목록과 출력 템플릿 헤딩의 시각은 서버가 계산해 따로 박아 넣는
/// 값이며, 돌아온 요약에서 "이어서" 지점을 읽는 `SummaryImport.parseLastUnitEnd`도
/// 구간 헤딩만 본다. 즉 줄마다 붙던 시각은 전부 중복이었고, Whisper 한 줄이 40자
/// 안팎이라 본문의 약 5분의 1을 차지하고 있었다.
///
/// 이 문서는 요약 프롬프트의 녹취 블록이자, BERT 같은 외부 문장 교정기에 넘겼다가
/// 되받을 교환 형식이다. 두 용도가 같은 렌더러를 써야 교정해 돌려받은 문장이
/// 요약에 들어가는 문장과 같다는 것이 구조적으로 보장된다.
enum TranscriptDocument {
  /// 돌려받은 파일이 이 프로그램에서 나간 전사인지 확인하는 표식이다. 아무 텍스트나
  /// 받아 문장을 덮어쓰면 복구할 길이 없으므로, 여는 검사는 반드시 있어야 한다.
  static let marker = "<!-- zoomcaption-transcript v1 -->"

  struct Options: Sendable {
    /// 줄마다 `S<id>`를 붙인다. 고쳐져 돌아온 줄을 원래 문장에 다시 맞추는 유일한
    /// 단서라, 왕복을 전제한 파일에는 반드시 있어야 한다. 모델에게 넘기는 녹취에는
    /// 넣지 않는다 — 요약과 무관한 숫자가 본문에 섞이면 인용으로 새어 나온다.
    var includeIDs: Bool
    /// 구간 머리글에만 시각 범위를 넣는다. 발화 줄에는 어떤 경우에도 넣지 않는다.
    var includeUnitTimes: Bool

    /// 요약 프롬프트용 — 구간 머리글의 시각은 남겨 모델이 구간 목록과 본문을 맞출 수 있게 한다.
    static let forPrompt = Options(includeIDs: false, includeUnitTimes: true)
    /// 외부 교정 왕복용 — 시각은 전부 빼고 문장 식별자만 남긴다.
    static let forEditing = Options(includeIDs: true, includeUnitTimes: false)
  }

  struct Edit: Sendable, Equatable {
    let id: Int
    let text: String
  }

  struct ParseResult: Sendable {
    let edits: [Edit]
    /// 파일에서 읽은 발화 줄 수. 적용된 수가 아니라 읽은 수다 — 라우트가 "몇 줄 중
    /// 몇 줄이 바뀌었다"를 말할 수 있어야 사용자가 잘못된 파일을 알아차린다.
    let lineCount: Int
  }

  enum DocumentError: LocalizedError {
    case notATranscript
    case noLines

    var errorDescription: String? {
      switch self {
      case .notATranscript:
        "이 파일은 ZoomCaption이 내보낸 전사 문서가 아닙니다."
      case .noLines:
        "문장 줄을 하나도 찾지 못했습니다. `S1 문장` 형식의 줄이 있어야 합니다."
      }
    }
  }

  /// 녹취 본문만 만든다. 프롬프트의 `<transcript>` 안에 그대로 들어간다.
  static func render(units: [LectureUnit], options: Options) -> String {
    var lines: [String] = []
    for unit in units {
      if !lines.isEmpty { lines.append("") }
      lines.append(unitHeader(for: unit, includeTimes: options.includeUnitTimes))
      for segment in unit.segments {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        lines.append(options.includeIDs ? "S\(segment.id) \(text)" : text)
        if let boundaryLabel = TranscriptStore.markdownLabel(for: segment.boundaryAfter) {
          // 저장 Markdown·프롬프트와 같은 라벨 함수를 거쳐야 경계 종류가 늘어도 한쪽만
          // 예전 문구를 쓰거나 경계를 빠뜨리는 일이 생기지 않는다.
          lines.append("> **\(boundaryLabel)**")
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  /// 사람이 열어 고칠 파일. 본문 앞에 표식과 규칙을 붙인다.
  static func file(units: [LectureUnit], title: String, options: Options = .forEditing) -> String {
    """
    # \(title) · 전사 원문

    \(marker)
    <!--
    규칙:
    - `S<번호>` 로 시작하는 줄의 **본문만** 고칩니다.
    - 번호를 바꾸거나 줄을 지우거나 새 줄을 넣지 마세요. 번호가 문장을 되찾는 유일한 단서입니다.
    - 줄을 비워 보내면 그 문장은 무시합니다(삭제가 아닙니다). 삭제는 프로그램의 편집 화면에서 하세요.
    - `===` 구간 머리글과 `> **강의 종료**` 줄은 그대로 두세요.
    -->

    \(render(units: units, options: options))
    """
  }

  /// `=== 2강 ===` 형태. 마크다운 헤딩(`##`)을 쓰지 않는 이유는 요약 출력 템플릿이
  /// 같은 문법의 `## N강 · ...` 헤딩을 쓰기 때문이다. 녹취 안에 같은 모양이 있으면
  /// 모델이 그것을 답의 일부로 베끼고, 돌아온 문서의 구간 수를 세는 검사도 흔들린다.
  static func unitHeader(for unit: LectureUnit, includeTimes: Bool) -> String {
    guard includeTimes else { return "=== \(unit.id)강 ===" }
    return "=== \(unit.id)강 · \(TranscriptStore.clock(unit.start))"
      + "~\(TranscriptStore.clock(unit.end)) ==="
  }

  /// 고쳐져 돌아온 문서에서 문장 id와 본문만 뽑는다. 적용은 호출부가 한다.
  static func parse(_ rawText: String) throws -> ParseResult {
    guard rawText.contains(marker) else { throw DocumentError.notATranscript }

    var edits: [Edit] = []
    var seen = Set<Int>()
    for rawLine in rawText.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("S") else { continue }
      let afterPrefix = line.dropFirst()
      let digits = afterPrefix.prefix(while: \.isNumber)
      guard !digits.isEmpty, let id = Int(digits) else { continue }
      let rest = afterPrefix.dropFirst(digits.count)
      // 숫자 바로 뒤가 공백이어야 문장 줄이다. `S3단계는`처럼 우연히 같은 모양으로
      // 시작하는 발화를 식별자로 오인하지 않는다.
      guard let firstCharacter = rest.first, firstCharacter == " " || firstCharacter == "\t"
      else { continue }
      // 같은 번호가 두 번 오면 앞의 것만 쓴다. 편집기가 문단을 복제한 경우 뒤쪽
      // 사본이 사용자가 고친 앞쪽을 덮어쓰지 않게 한다.
      guard seen.insert(id).inserted else { continue }
      edits.append(Edit(id: id, text: rest.trimmingCharacters(in: .whitespaces)))
    }

    guard !edits.isEmpty else { throw DocumentError.noLines }
    return ParseResult(edits: edits, lineCount: edits.count)
  }
}

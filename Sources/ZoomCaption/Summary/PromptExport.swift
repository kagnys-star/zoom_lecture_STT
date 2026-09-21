import Foundation

/// 온라인 LLM 웹 UI에 붙여넣을 프롬프트를 만든다.
enum PromptTarget: String, Sendable, CaseIterable {
  case claude
  case chatgpt
  case gemini

  var displayName: String {
    switch self {
    case .claude: "Claude"
    case .chatgpt: "ChatGPT"
    case .gemini: "Gemini"
    }
  }

  var newChatURL: String {
    switch self {
    case .claude: "https://claude.ai/new"
    case .chatgpt: "https://chatgpt.com/"
    case .gemini: "https://gemini.google.com/app"
    }
  }

  /// 채팅 본문 복사는 렌더된 문서를 역변환해 강조·목록 들여쓰기를 망가뜨릴 수
  /// 있으므로, 마크다운 원문을 보존하는 각 서비스의 문서 용기와 제목을 명시한다.
  /// 제목이 없으면 내려받은 파일이 `Untitled.md`가 되어 나중에 어느 수업인지
  /// 구분할 수 없으므로 강의 제목은 호출할 때마다 실제 값으로 넣어야 한다.
  func outputContainerInstruction(lectureTitle: String) -> String {
    switch self {
    case .claude:
      """
      요약 전체를 마크다운 아티팩트(artifact) 하나로 만들어라.
      아티팩트 제목은 "\(lectureTitle)_요약"으로 한다.
      사용자는 이 아티팩트를 .md 파일로 내려받아 프로그램에 넣을 것이다.
      따라서 아티팩트 안에는 아래 템플릿 외에 아무것도 넣지 말라.
      """
    case .chatgpt:
      // 코드 인터프리터를 켜면 모델이 요약을 파이썬 문자열로 다시 만들면서 느려지고
      // 긴 결과가 잘릴 수 있으므로 캔버스에 직접 쓰도록 경로까지 제한한다.
      """
      요약 전체를 캔버스(Canvas) 문서 하나로 만들어라.
      캔버스 제목은 "\(lectureTitle)_요약"으로 한다.
      사용자는 이 캔버스를 .md 파일로 내려받아 프로그램에 넣을 것이다.
      따라서 캔버스 안에는 아래 템플릿 외에 아무것도 넣지 말라.
      파이썬이나 파일 생성 도구를 쓰지 말고 캔버스에 직접 마크다운을 써라.
      """
    case .gemini:
      """
      요약 전체를 캔버스(Canvas) 문서 하나로 만들어라.
      캔버스 제목은 "\(lectureTitle)_요약"으로 한다.
      사용자는 이 캔버스를 마크다운(.md)으로 내보내 프로그램에 넣을 것이다.
      따라서 캔버스 안에는 아래 템플릿 외에 아무것도 넣지 말라.
      """
    }
  }
}

enum PromptExport {
  struct Bundle: Sendable {
    let text: String
    let unitCount: Int
    let characterCount: Int
  }

  enum PromptExportError: LocalizedError {
    case emptyTranscript
    case noLectureUnit

    var errorDescription: String? {
      switch self {
      case .emptyTranscript:
        "Whisper 전사가 아직 준비되지 않았거나 내보낼 내용이 없습니다."
      case .noLectureUnit:
        "강의 경계에서 내보낼 시간대를 만들지 못했습니다."
      }
    }
  }

  /// - Parameter characterBudget: 분할 상한. 지금은 Pro 계정 전제라 항상 nil(분할 없음)로
  ///   호출한다. 무료 플랜 대응이 필요해지면 이 인자만 채우면 된다.
  static func makeBundle(units: [LectureUnit],
                         title: String,
                         glossary: String,
                         target: PromptTarget,
                         characterBudget: Int? = nil) throws -> Bundle {
    guard !units.isEmpty else { throw PromptExportError.noLectureUnit }
    guard units.contains(where: { !$0.segments.isEmpty }) else {
      throw PromptExportError.emptyTranscript
    }

    // 줄마다 붙던 `[00:12:34] ` 대신 구간 머리글에 시각 범위를 한 번씩만 남겨,
    // 모델이 아래 구간 목록과 본문을 맞추면서 프롬프트 길이는 줄인다.
    let transcriptBody = TranscriptDocument.render(units: units)

    // 현재 호출자는 항상 nil을 보내 원문 전체를 한 번에 전달한다. non-nil 예산은 줄
    // 경계만 사용해 묶어 두므로, 이후 무료 플랜 다중 전송을 붙여도 발화를 자르지 않는다.
    let transcript = transcriptBlocks(lines: transcriptBody.components(separatedBy: "\n"),
                                      characterBudget: characterBudget)
      .joined(separator: "\n")
    let glossaryBlock = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
    let unitRanges = units.map {
      "- \($0.id)강: \(TranscriptStore.clock($0.start))~\(TranscriptStore.clock($0.end))"
    }.joined(separator: "\n")
    let unitTemplates = units.map(outputTemplate).joined(separator: "\n\n")

    let groundingRule = "2. 녹취에 실제로 나온 내용만 쓴다. 외부 지식으로 설명을 보충하지 않는다."
    let reinforcedGroundingRule = groundingRule
      + "\n녹취에 없는 내용을 한 문장이라도 추가하면 실패로 간주한다."
    let onlineSystem = SummaryPrompts.unitSystem.replacingOccurrences(
      of: groundingRule, with: reinforcedGroundingRule)

    // 대형 모델일수록 익숙한 외부 지식으로 빈틈을 보충하려 하므로 같은 근거 제한을
    // 프롬프트 앞과 녹취 뒤에 한 번씩 두어 긴 입력에서도 규칙을 잊지 않게 한다.
    let prompt = """
    [역할]
    \(onlineSystem)

    [강의 정보]
    강의 제목: \(title)
    교안 용어 철자 힌트: \(glossaryBlock.isEmpty ? "없음" : glossaryBlock)

    [구간 경계]
    녹취는 `=== N강 ===` 머리글로 구간이 나뉘고, `> **강의 종료**` 와 `> **녹음 종료**`
    줄이 그 구간의 끝이다. 발화 줄에는 시각이 없으니 구간 판단은 이 두 표시만 쓴다.
    이것은 확정된 경계이므로 임의로 합치거나 나누지 말라.
    이 녹취에는 구간이 정확히 \(units.count)개 있다:
    \(unitRanges)

    [출력 위치]
    \(target.outputContainerInstruction(lectureTitle: title))
    채팅 본문에는 만들었다는 한 줄 외에 아무것도 쓰지 말라.
    그 안에는 아래 템플릿만 있어야 한다 — 인사말·설명·코드펜스를 넣지 말라.

    [출력 형식]
    아래 템플릿을 그대로 채워 마크다운만 출력하라.
    핵심과 용어의 개수는 내용에 따라 줄여도 된다. 개수를 채우려고 만들지 말라.

    # 전체 강의 요약

    ## 전체 개요

    (전체 강의가 무엇을 어떤 흐름으로 다뤘는지 1~3문장)

    \(unitTemplates)

    <transcript>
    \(transcript)
    </transcript>

    위 규칙 2를 다시 확인하라. 녹취에 없는 내용은 쓰지 않는다.
    """
    return Bundle(text: prompt, unitCount: units.count, characterCount: prompt.count)
  }

  /// 예산을 쓸 때도 문장 중간을 자르지 않는다. 지금은 한 요청에 다시 합치지만 블록
  /// 경계를 미리 보존해 두어 향후 무료 플랜 다중 전송이 같은 입력 규칙을 재사용한다.
  private static func transcriptBlocks(lines: [String], characterBudget: Int?) -> [String] {
    guard let characterBudget, characterBudget > 0 else { return [lines.joined(separator: "\n")] }
    var blocks: [String] = []
    var pendingLines: [String] = []
    var pendingCharacterCount = 0
    for line in lines {
      let addedCharacterCount = line.count + (pendingLines.isEmpty ? 0 : 1)
      if !pendingLines.isEmpty, pendingCharacterCount + addedCharacterCount > characterBudget {
        blocks.append(pendingLines.joined(separator: "\n"))
        pendingLines.removeAll(keepingCapacity: true)
        pendingCharacterCount = 0
      }
      pendingLines.append(line)
      pendingCharacterCount += line.count + (pendingLines.count == 1 ? 0 : 1)
    }
    if !pendingLines.isEmpty { blocks.append(pendingLines.joined(separator: "\n")) }
    return blocks
  }

  /// 이 골격을 코드에서 생성해야 단위 수와 시간 범위가 바뀌어도 Renderer와 같은
  /// 헤딩·목록 문법을 모든 구간에 빠짐없이 반복할 수 있다.
  private static func outputTemplate(for unit: LectureUnit) -> String {
    """
    ## \(unit.id)강 · \(TranscriptStore.clock(unit.start))~\(TranscriptStore.clock(unit.end))

    **(이 구간의 중심 주제를 짧은 명사구로. 전체 강의 제목을 복사하지 말 것)**

    ### 구간 요약

    (이 구간에서 무엇을 어떤 흐름으로 설명했는지 2~4문장)

    ### 핵심

    - **(반드시 기억할 핵심 주장)** (그 주장이 중요한 이유·작동 원리·다른 개념과의 관계)

    ### 핵심 용어

    - **(용어)** — (녹취에서 설명한 뜻을 한 문장으로. 용어명을 되풀이하지 말 것)
    """
  }
}

import Foundation
import AVFoundation

// MARK: - 자가진단
//
// 오디오 권한·Zoom·화면 없이 각 경로만 따로 확인하는 명령들이다.
// 앱을 띄우지 않고 터미널에서 바로 돌린다.

/// WebUI 마크업과 스크립트의 정적 계약을 검사한다.
///
/// 이 앱은 HTML과 JS를 문자열로 함께 싣기 때문에 존재하지 않는 id 하나를 참조해도
/// 그 줄 아래 스크립트가 전부 멈춘다. 메인/사이드 탭을 옮길 때 같은 회귀가 생기지
/// 않도록 정적 id 참조와 탭 대상을 확인한다.
func runWebUIContractChecks() -> Never {
  var failures: [String] = []
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("✓ \(message)") }
    else { print("✗ \(message)"); failures.append(message) }
  }
  func captures(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
      guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
      return ns.substring(with: match.range(at: 1))
    }
  }

  let markup = WebUI.markup
  let script = WebUI.script
  let ids = captures(#"\bid="([A-Za-z][A-Za-z0-9_-]*)""#, in: markup)
  let duplicateIDs = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
  check(duplicateIDs.isEmpty, "HTML id가 중복되지 않는다")

  let staticReferences = Set(captures(#"\$\('#([A-Za-z][A-Za-z0-9_-]*)'\)"#, in: script))
  // 두 요소는 스크립트가 필요할 때 innerHTML/createElement로 만든 뒤 참조한다.
  let dynamicIDs: Set<String> = ["toast", "btnClearDoc", "btnQuietClean", "btnQuietRestore"]
  let missing = staticReferences.subtracting(Set(ids)).subtracting(dynamicIDs).sorted()
  check(missing.isEmpty, "JS의 정적 id 참조가 마크업에 모두 존재한다")

  let workspaceTargets = captures(#"data-view="([A-Za-z0-9_-]+)""#, in: markup)
  check(!workspaceTargets.isEmpty && workspaceTargets.allSatisfy { ids.contains("view-\($0)") },
        "모든 메인 탭에 대응하는 화면이 존재한다")
  let sideTargets = captures(#"data-tab="([A-Za-z0-9_-]+)""#, in: markup)
  check(!sideTargets.isEmpty && sideTargets.allSatisfy { ids.contains("panel-\($0)") },
        "모든 사이드 탭에 대응하는 패널이 존재한다")
  check(!markup.contains("data-tab=\"sum\"") && !markup.contains("id=\"panel-sum\""),
        "요약이 사이드 탭에 남아 있지 않는다")
  if let summary = markup.range(of: "id=\"view-summary\""),
     let aside = markup.range(of: "<aside>") {
    check(summary.lowerBound < aside.lowerBound, "요약 화면이 보조 사이드바 밖에 있다")
  } else {
    check(false, "요약 화면과 사이드바 위치를 찾을 수 있다")
  }

  if failures.isEmpty {
    print("WebUI 계약 자가검사 통과")
    exit(0)
  }
  print("WebUI 계약 자가검사 실패: \(failures.count)건")
  if !missing.isEmpty { print("누락 id: \(missing.joined(separator: ", "))") }
  if !duplicateIDs.isEmpty { print("중복 id: \(duplicateIDs.joined(separator: ", "))") }
  exit(1)
}

/// 모델 호출 없이 시간대 경계·청킹·용어 보존·렌더링 규칙을 회귀 검사한다.
func runSummaryPipelineChecks() -> Never {
  var failures: [String] = []
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("✓ \(message)") }
    else { print("✗ \(message)"); failures.append(message) }
  }
  func input(_ id: Int, _ start: Double, _ end: Double, _ text: String,
             paragraph: Int?, boundary: TranscriptBoundary? = nil) -> SummaryInputSegment {
    SummaryInputSegment(id: id, start: start, end: end, text: text,
                        paragraph: paragraph, boundaryAfter: boundary)
  }

  let source = [
    input(1, 0, 10, "첫 설명", paragraph: 1),
    input(2, 10, 20, "첫 강의 끝", paragraph: 2, boundary: .lectureEnded),
    input(3, 30, 40, "둘째 설명", paragraph: 3),
    input(4, 40, 50, "둘째 강의 끝", paragraph: 4, boundary: .lectureEnded),
    input(5, 60, 70, "마지막 꼬리", paragraph: 5),
  ]
  let units = SummaryChunker.makeUnits(from: source)
  check(units.count == 3, "boundaryAfter 두 개와 마지막 꼬리가 세 시간대를 만든다")
  check(units.map { $0.segments.map(\.id) } == [[1, 2], [3, 4], [5]],
        "모든 입력 세그먼트가 원래 순서로 정확히 한 번 포함된다")

  let paragraphsOnly = SummaryChunker.makeUnits(from: [
    input(1, 0, 10, "문단 하나", paragraph: 1),
    input(2, 10, 20, "문단 둘", paragraph: 2),
    input(3, 20, 30, "문단 셋", paragraph: 3),
  ])
  check(paragraphsOnly.count == 1, "paragraph 변화만으로 상위 강의가 나뉘지 않는다")

  let longSegments = (1...8).map { index in
    input(index, Double(index * 10), Double(index * 10 + 5),
          String(repeating: "가", count: 30), paragraph: (index - 1) / 2)
  }
  let longUnit = SummaryChunker.makeUnits(from: longSegments)[0]
  let chunks = SummaryChunker.makeChunks(for: longUnit, tokenBudget: 120, tokensPerCharacter: 1)
  check(chunks.count > 1, "예산을 넘는 시간대가 내부 청크로 나뉜다")
  check(chunks.enumerated().allSatisfy { offset, chunk in
    chunk.partIndex == offset + 1 && chunk.partCount == chunks.count
  }, "내부 청크 번호와 전체 개수가 일관된다")
  check((1...8).allSatisfy { index in
    let stamp = "[\(TranscriptStore.clock(Double(index * 10)))]"
    return chunks.filter { $0.transcript.contains(stamp) }.count == 1
  }, "내부 청킹이 입력 세그먼트를 누락하거나 중복하지 않는다")

  let terms = SummaryRenderer.deduplicateTerms([
    .init(term: "L1 정규화", meaning: "가중치의 절댓값 합을 손실에 더해 과적합을 줄이는 방법"),
    .init(term: "L2 정규화", meaning: "가중치의 제곱합을 손실에 더해 과적합을 줄이는 방법"),
    .init(term: "ReLU", meaning: "음수를 0으로 만드는 활성화 함수"),
    .init(term: " re-lu ", meaning: "다른 표기"),
    .init(term: "ReLU 함수", meaning: "음수를 0으로 만드는 활성화 함수"),
  ])
  check(terms.map(\.term) == ["L1 정규화", "L2 정규화", "ReLU", "ReLU 함수"],
        "용어명 완전 동치만 제거하고 L1/L2 및 접두어 용어를 보존한다")

  // SummaryJob은 예전 isSummarizing/summaryGeneration 짝을 대체한다. 그 짝은 해제
  // 조건이 세 갈래로 갈라져 있어 generation이 진행 중에 바뀌면 어느 쪽도 플래그를 끄지
  // 못했고, 앱이 "요약 중"에 갇혀 녹음 시작까지 막혔다. 아래 검사는 그 구조가 다시
  // 들어오지 못하도록 수명·취소·진행률의 계약을 고정한다.
  do {
    let sessionDirectory = URL(fileURLWithPath: "/tmp/zoomcaption-selftest-session")
    let job = SummaryJob(sessionDir: sessionDirectory)
    check(job.sessionDir == sessionDirectory, "작업이 시작 시점의 세션을 기억한다")
    check(job.progress.total == 0, "진행률은 0에서 시작한다")

    job.recordProgress(completed: 3, total: 7)
    check(job.progress.completed == 3 && job.progress.total == 7,
          "진행률을 작업에 남겨 새로고침 뒤에도 복원할 수 있다")

    let runningTask = Task { () -> Void in try? await Task.sleep(for: .seconds(30)) }
    job.attach(runningTask)
    check(!runningTask.isCancelled, "붙인 직후에는 취소되지 않은 상태다")
    job.cancel()
    check(runningTask.isCancelled, "cancel이 실제 Task까지 전달된다")

    // 라우트가 Task를 만들어 붙이는 사이에 사용자가 취소를 누를 수 있다. 그 취소를
    // 잃어버리면 사용자는 멈춘 줄 아는데 8B 모델이 끝까지 돈다.
    let earlyCancelJob = SummaryJob(sessionDir: nil)
    earlyCancelJob.cancel()
    let lateTask = Task { () -> Void in try? await Task.sleep(for: .seconds(30)) }
    earlyCancelJob.attach(lateTask)
    check(lateTask.isCancelled, "attach 전에 들어온 취소를 잃지 않는다")
  }

  // 온라인 경로도 별도 경계 계산을 만들지 않고 Chunker 결과를 그대로 써야, 로컬
  // Qwen과 웹 LLM이 같은 녹취를 서로 다른 강의 수로 해석하는 회귀를 막을 수 있다.
  let promptSegments = [
    input(11, 0, 12, "첫 강의", paragraph: 1, boundary: .lectureEnded),
    input(12, 20, 34, "둘째 강의", paragraph: 2, boundary: .recordingStopped),
    input(13, 40, 55, "셋째 강의", paragraph: 3),
  ]
  let promptUnits = SummaryChunker.makeUnits(from: promptSegments)
  do {
    let bundle = try PromptExport.makeBundle(
      units: promptUnits, title: "온라인 테스트", glossary: "", target: .claude)
    check(bundle.unitCount == 3, "온라인 프롬프트가 두 경계와 마지막 꼬리를 세 구간으로 보존한다")
    check(bundle.text.contains("> **강의 종료**") && bundle.text.contains("> **녹음 종료**"),
          "온라인 프롬프트에 두 구조화 경계 라벨이 모두 들어간다")
    let expectedRanges = promptUnits.map {
      "- \($0.id)강: \(TranscriptStore.clock($0.start))~\(TranscriptStore.clock($0.end))"
    }
    check(expectedRanges.allSatisfy { bundle.text.contains($0) },
          "프롬프트 구간 목록이 SummaryChunker의 실제 시간 범위와 일치한다")
    check(bundle.text.contains("아티팩트"), "Claude 프롬프트가 마크다운 아티팩트를 요구한다")

    // 근거 제한 강화는 unitSystem의 규칙 2 문장을 문자열 치환으로 찾는다. 규칙 문구가
    // 바뀌면 치환이 조용히 아무 일도 하지 않아 온라인 프롬프트만 약해지므로, 강화된
    // 문장이 실제로 들어갔는지를 확인해 그 무음 실패를 드러낸다.
    check(bundle.text.contains("녹취에 없는 내용을 한 문장이라도 추가하면 실패로 간주한다."),
          "온라인 프롬프트의 근거 제한 강화 문장이 실제로 치환된다")

    // 내보낸 프롬프트에는 출력 템플릿이 들어 있어 요약과 헤딩이 같다. 사용자가 받은
    // 프롬프트 .md를 그대로 끌어다 놓아도 멀쩡한 요약을 덮어쓰지 않아야 한다.
    do {
      _ = try SummaryImport.validate(bundle.text, expectedUnitCount: bundle.unitCount)
      check(false, "내보낸 프롬프트를 요약으로 가져오지 않는다")
    } catch SummaryImport.ImportError.exportedPrompt {
      check(true, "내보낸 프롬프트를 요약으로 가져오지 않는다")
    } catch {
      check(false, "내보낸 프롬프트가 exportedPrompt로 거부된다: \(error.localizedDescription)")
    }

    let chatGPTBundle = try PromptExport.makeBundle(
      units: promptUnits, title: "온라인 테스트", glossary: "", target: .chatgpt)
    check(chatGPTBundle.text.contains("캔버스") && chatGPTBundle.text.contains("파이썬"),
          "ChatGPT 프롬프트가 캔버스를 요구하고 파이썬 경로를 금지한다")
  } catch {
    check(false, "온라인 프롬프트를 오류 없이 만든다: \(error.localizedDescription)")
  }

  // 범위를 좁혀도 구간 번호가 1부터 다시 시작하면, 여러 번 나눠 만든 요약을 이어 붙일 때
  // 3강이 두 개 생긴다. Store가 붙인 전체 기준 id가 프롬프트 템플릿까지 그대로 와야 한다.
  do {
    let laterUnits = Array(promptUnits.dropFirst())
    let bundle = try PromptExport.makeBundle(
      units: laterUnits, title: "온라인 테스트", glossary: "", target: .claude)
    check(bundle.text.contains("## 2강 · ") && bundle.text.contains("## 3강 · "),
          "범위를 좁힌 프롬프트가 전체 기준 구간 번호를 유지한다")
    check(!bundle.text.contains("## 1강 · "),
          "범위를 좁힌 프롬프트가 구간 번호를 1부터 다시 매기지 않는다")
    check(bundle.unitCount == 2, "범위를 좁히면 기대 구간 수도 함께 줄어든다")
  } catch {
    check(false, "범위를 좁힌 프롬프트를 만든다: \(error.localizedDescription)")
  }

  // 내려받은 파일 이름이 문서 제목에서 나오므로, 제목을 지정하지 않으면 사용자의
  // 다운로드 폴더에 어느 강의인지 알 수 없는 파일이 쌓인다.
  for target in PromptTarget.allCases {
    do {
      let bundle = try PromptExport.makeBundle(
        units: promptUnits, title: "운영체제 3주차", glossary: "", target: target)
      check(bundle.text.contains("운영체제 3주차_요약"),
            "\(target.displayName) 프롬프트가 강의 제목으로 문서 제목을 지정한다")
      check(bundle.text.contains("내려받") || bundle.text.contains("내보내"),
            "\(target.displayName) 프롬프트가 파일로 가져갈 것임을 알린다")
    } catch {
      check(false, "\(target.displayName) 프롬프트를 만든다: \(error.localizedDescription)")
    }
  }

  // 부분 요약을 가져왔을 때 "이어서" 지점은 전체 전사 끝이 아니라 요약문이 말하는
  // 마지막 구간 끝이어야 한다. 파일을 끌어다 놓은 경우 이 파싱이 유일한 근거다.
  do {
    let partialSummary = [
      "# 전체 강의 요약", "", "## 전체 개요", "", "개요다.", "",
      "## 2강 · 00:10:00~00:20:00", "", "### 구간 요약", "", "앞 구간.", "",
      "## 3강 · 00:20:00~00:40:00", "", "### 구간 요약", "", "뒤 구간.",
    ].joined(separator: "\n")
    let parsed = try SummaryImport.validate(partialSummary, expectedUnitCount: 2)
    check(parsed.lastUnitEnd == 2400,
          "마지막 구간 헤딩의 끝 시각을 이어서 지점으로 읽는다")
    check(parsed.unitCount == 2, "구간 헤딩 수를 함께 돌려준다")

    let shortClock = [
      "## 전체 개요", "", "개요다.", "",
      "## 1강 · 00:00~10:00", "", "### 구간 요약", "", "내용.",
    ].joined(separator: "\n")
    let shortParsed = try SummaryImport.validate(shortClock, expectedUnitCount: 1)
    check(shortParsed.lastUnitEnd == 600, "MM:SS 형식의 구간 헤딩도 읽는다")

    // 헤딩이 깨진 답변을 조용히 전체 끝으로 폴백하면 이어서 지점이 또 틀려도
    // 사용자가 알 수 없다. 저장은 하되 경고는 반드시 나와야 한다.
    let noHeading = [
      "## 전체 개요", "",
      "구간 헤딩 없이 개요만 있는 답변이다. 모델이 형식을 지키지 않은 경우를 흉내 낸다.",
    ].joined(separator: "\n")
    let noHeadingParsed = try SummaryImport.validate(noHeading, expectedUnitCount: 0)
    check(noHeadingParsed.lastUnitEnd == nil,
          "구간 헤딩이 없으면 이어서 지점을 추측하지 않는다")
    check(noHeadingParsed.warning?.contains("이어서") == true,
          "이어서 지점을 못 읽으면 경고로 알린다")
  } catch {
    check(false, "부분 요약의 구간 범위를 읽는다: \(error.localizedDescription)")
  }

  do {
    let fenced = """
    ```markdown
    # 전체 강의 요약

    ## 전체 개요

    코드펜스 요약
    ```
    """
    let fencedResult = try SummaryImport.validate(fenced, expectedUnitCount: 0)
    check(fencedResult.markdown.hasPrefix("# 전체 강의 요약"),
          "문서 전체를 감싼 코드펜스를 벗긴다")

    let conversational = """
    알겠습니다. 아래는 요청하신 요약입니다.

    ## 전체 개요

    앞의 잡담을 제거한 요약
    """
    let conversationalResult = try SummaryImport.validate(conversational, expectedUnitCount: 0)
    check(conversationalResult.markdown.hasPrefix("## 전체 개요"),
          "요약 헤딩 앞의 채팅 잡담을 제거한다")
  } catch {
    check(false, "온라인 요약 정규화가 유효한 입력을 보존한다: \(error.localizedDescription)")
  }

  do {
    _ = try SummaryImport.validate("요약과 무관한 임의 텍스트", expectedUnitCount: 0)
    check(false, "전체 개요가 없는 클립보드 텍스트를 거부한다")
  } catch SummaryImport.ImportError.notASummary {
    check(true, "전체 개요가 없는 클립보드 텍스트를 거부한다")
  } catch {
    check(false, "무관한 텍스트가 notASummary로 거부된다")
  }

  do {
    let missingUnit = """
    # 전체 강의 요약

    ## 전체 개요

    두 구간만 반환된 요약

    ## 1강 · 00:00:00~00:00:10

    첫째

    ## 2강 · 00:00:10~00:00:20

    둘째
    """
    let importResult = try SummaryImport.validate(missingUnit, expectedUnitCount: 3)
    check(importResult.warning != nil, "구간 수가 달라도 저장 가능한 경고로 반환한다")
  } catch {
    check(false, "구간 수 불일치는 가져오기를 거부하지 않는다: \(error.localizedDescription)")
  }

  if let firstUnit = units.first {
    let summary = UnitSummary(
      unitId: 1, title: "합성곱의 원리", summary: "필터가 특징을 추출하는 과정을 설명했다.",
      keyInsights: [.init(point: "필터는 특징을 찾는 기준이다.",
                          explanation: "같은 가중치를 위치마다 적용한다.")],
      terms: [.init(term: "필터", meaning: "국소 특징을 추출하는 가중치 집합")])
    let markdown = SummaryRenderer.render(.init(
      overview: "합성곱의 기본 원리를 다뤘다.",
      units: [.init(unit: firstUnit, summary: summary)]))
    check(markdown.contains("## 1강 · 00:00:00~00:00:20"), "코드가 원본 시간 범위를 렌더링한다")
    check(markdown.contains("### 구간 요약") && markdown.contains("### 핵심"),
          "시간대별 요약과 핵심 섹션이 출력된다")
    check(!markdown.contains("과제 · 공지"), "과제·공지 섹션이 출력되지 않는다")
    check(markdown.components(separatedBy: "- **필터는 특징을 찾는 기준이다.**").count - 1 == 1,
          "핵심 한 개도 네 개로 채우지 않고 그대로 출력한다")
  }

  if failures.isEmpty {
    print("요약 파이프라인 자가검사 통과")
    exit(0)
  }
  print("요약 파이프라인 자가검사 실패: \(failures.count)건")
  exit(1)
}

func runSelfTest(path: String, localeID: String, terms: [String] = []) async -> Never {
  let url = URL(fileURLWithPath: path)
  do {
    let locale = try await TrackTranscriber.prepareAssets(locale: Locale(identifier: localeID))
    let format = try await TrackTranscriber.analyzerFormat(locale: locale)
    log("모델 \(locale.identifier), 목표 포맷 \(format.sampleRate)Hz ch\(format.channelCount)")

    let file = try AVAudioFile(forReading: url)
    log("입력 \(file.fileFormat.sampleRate)Hz ch\(file.fileFormat.channelCount), \(file.length) 프레임")

    let collected = NSMutableArray()
    let tx = TrackTranscriber()
    if !terms.isEmpty { log("용어 힌트 \(terms.count)개") }
    try await tx.start(locale: locale, audioFormat: format, contextualStrings: terms,
                       onFinal: { s, _, t, _ in
                         log("  [\(String(format: "%.1f", s))s] \(t)")
                         collected.add(t)
                       },
                       onVolatile: { _ in })

    let chunk: AVAudioFrameCount = 4800
    while file.framePosition < file.length {
      guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
      try file.read(into: buf, frameCount: chunk)
      if buf.frameLength == 0 { break }
      tx.feed(buf)
    }
    await tx.finish()
    try? await Task.sleep(for: .seconds(1))

    if collected.count > 0 {
      log("✅ 음성 인식 경로 정상 (\(collected.count)개 발화)")
      exit(0)
    } else {
      log("❌ 인식 결과 없음 — 오디오에 말소리가 있는지 확인하세요")
      exit(1)
    }
  } catch {
    log("❌ 자가진단 실패: \(error.localizedDescription)")
    exit(1)
  }
}

/// 녹취 텍스트 파일로 요약만 돌려본다. `--sumtest <기록.txt> [--pdf <교안.pdf>]`
func runSumTest(path: String, pdf: String?) async -> Never {
  do {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var glossary = ""
    if let pdf {
      let r = try DomainKnowledge.analyze(pdf: Data(contentsOf: URL(fileURLWithPath: pdf)))
      glossary = DomainKnowledge.glossary(r.terms)
      log("교안 용어 \(r.terms.count)개 (\(r.analyzer))")
    }
    log("입력 \(text.count)자, 요약 엔진: \(await Summarizer.currentEngine().label)")
    let t0 = Date()
    let segment = SummaryInputSegment(id: 1, start: 0, end: 0, text: text,
                                      paragraph: nil, boundaryAfter: nil)
    let unit = LectureUnit(id: 1, start: segment.start, end: segment.end,
                           segments: [segment])
    let result = try await Summarizer.summarize(
      units: [unit], title: "테스트 수업", glossary: glossary) { done, total in
        if done < total { log("  진행 \(done)/\(total)") }
      }
    log("소요 \(String(format: "%.1f", Date().timeIntervalSince(t0)))초\n")
    print(result)
    OllamaClient.shutdownSpawnedServer()
    exit(0)
  } catch {
    log("❌ \(error.localizedDescription)")
    exit(1)
  }
}

/// 교안 PDF 분석만 돌려본다. `--pdftest <파일.pdf>`
func runPDFTest(path: String, useLLM: Bool) async -> Never {
  do {
    let r = try DomainKnowledge.analyze(pdf: Data(contentsOf: URL(fileURLWithPath: path)))
    log("\(r.pages)쪽, \(r.characters)자, 분석기: \(r.analyzer), 스캔본: \(r.looksScanned)")
    log("용어 \(r.terms.count)개 (상위 40): \(r.terms.prefix(40).joined(separator: ", "))")
    if !r.droppedBoilerplate.isEmpty {
      log("머리말·꼬리말로 걸러냄 \(r.droppedBoilerplate.count)개: "
        + r.droppedBoilerplate.prefix(20).joined(separator: ", "))
    }
    if useLLM, !r.terms.isEmpty, await OllamaClient.ensureServer(),
       let installed = await OllamaClient.installedModels(),
       let model = OllamaClient.pickModel(from: installed) {
      let t0 = Date()
      if let filtered = await OllamaClient.filterLectureTerms(r.terms, model: model) {
        log("── LLM 정제 (\(model), \(String(format: "%.0f", Date().timeIntervalSince(t0)))초) ──")
        log("\(r.terms.count)개 → \(filtered.count)개")
        log("남김(상위 40): \(filtered.prefix(40).joined(separator: ", "))")
        let removed = r.terms.filter { !filtered.contains($0) }
        log("제거(상위 30): \(removed.prefix(30).joined(separator: ", "))")
      }
      OllamaClient.shutdownSpawnedServer()
    }
    exit(r.looksScanned ? 1 : 0)
  } catch {
    log("❌ \(error.localizedDescription)")
    exit(1)
  }
}

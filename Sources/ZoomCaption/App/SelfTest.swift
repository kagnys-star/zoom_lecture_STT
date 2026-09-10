import Foundation
import AVFoundation

// MARK: - 자가진단
//
// 오디오 권한·Zoom·화면 없이 각 경로만 따로 확인하는 명령들이다.
// 앱을 띄우지 않고 터미널에서 바로 돌린다.

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
    let result = try await Summarizer.summarize(
      segments: [segment], title: "테스트 수업", glossary: glossary) { done, total in
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

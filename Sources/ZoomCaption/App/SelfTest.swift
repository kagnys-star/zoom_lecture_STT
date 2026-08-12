import Foundation
import AVFoundation

// MARK: - 자가진단
//
// 오디오 권한·Zoom·화면 없이 각 경로만 따로 확인하는 명령들이다.
// 앱을 띄우지 않고 터미널에서 바로 돌린다.

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
      let r = try DomainKnowledge.analyze(pdf: URL(fileURLWithPath: pdf))
      glossary = DomainKnowledge.glossary(r.terms)
      log("교안 용어 \(r.terms.count)개 (\(r.analyzer))")
    }
    log("입력 \(text.count)자, 요약 엔진: \(await Summarizer.currentEngine().label)")
    let t0 = Date()
    let result = await Summarizer.summarize(transcript: text, title: "테스트 수업", glossary: glossary) { done, total in
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
    let r = try DomainKnowledge.analyze(pdf: URL(fileURLWithPath: path))
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

import Foundation
import AVFoundation
import AppKit

/// 교안 PDF, 요약 생성·저장·열기, 제목, 내보내기, 완전 종료.

extension ZoomCaptionApp {
  func summaryRoutes(_ req: HTTPRequest) async -> Route? {
    switch (req.method, req.path) {
    // ── 교안 PDF ──
    case ("POST", "/api/domain"):
      return .response(await handleDomainUpload(req))

    case ("POST", "/api/domain/cache/clear"):
      DomainCache.clear()
      return .response(.json(["ok": true]))

    case ("POST", "/api/domain/clear"):
      store.domainTerms = []
      store.domainSource = nil
      autosave()
      return .response(.json(["ok": true]))

    // ── 요약 ──
    case ("POST", "/api/summarize"):
      let from = req.json(SummarizeRequest.self)?.from
      if stateLock.withLock({ running || stopping }) {
        return .response(.json(["ok": false,
                                "error": "녹음과 Whisper 정리가 끝난 뒤 요약해 주세요."]))
      }
      let snapshot = store.whisperSummarySnapshot(from: from)
      guard !snapshot.isEmpty else {
        return .response(.json(["ok": false,
                                "error": from == nil
                                  ? "Whisper 전사가 아직 준비되지 않았습니다."
                                  : "지정한 시각 이후의 Whisper 전사가 없습니다."]))
      }
      guard case .ollama = await Summarizer.currentEngine() else {
        return .response(.json(["ok": false,
                                "error": "쓸 수 있는 Qwen 모델이 없습니다. `ollama pull qwen3:8b`로 내려받으세요."]))
      }
      let generation = stateLock.withLock { () -> Int? in
        guard !isSummarizing else { return nil }
        isSummarizing = true
        summaryGeneration += 1
        return summaryGeneration
      }
      guard let generation else {
        return .response(.json(["ok": false, "error": "요약이 이미 진행 중입니다."]))
      }
      Task { await self.runSummary(segments: snapshot, from: from, generation: generation) }
      return .response(.json(["ok": true]))

    case ("POST", "/api/summary/save"):
      guard let summary = store.summary, !summary.isEmpty else {
        return .response(.json(["ok": false, "error": "저장할 요약이 없습니다."]))
      }
      let r = req.json(SaveSummaryRequest.self)
      let dir = (r?.dir?.isEmpty == false) ? URL(fileURLWithPath: r!.dir!)
                                           : (store.sessionDir ?? effectiveBaseDir)
      var name = SessionStore.sanitize(r?.filename ?? "")
      if name.isEmpty || name == "수업" { name = "\(SessionStore.sanitize(store.title))_요약" }
      if !name.lowercased().hasSuffix(".md") { name += ".md" }
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try store.markdownSummaryOnly().write(to: url, atomically: true, encoding: .utf8)
        store.rememberSummaryFile(url)
        autosave()
        log("요약 저장: \(url.path)")
        return .response(.json(["ok": true, "path": url.path,
                                "summaries": summariesJSON()]))
      } catch {
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    case ("GET", "/api/summaries"):
      return .response(.json(["summaries": summariesJSON()]))

    case ("POST", "/api/summary/open"):
      guard let path = req.json(OpenRequest.self)?.path, !path.isEmpty,
            let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        return .response(.json(["ok": false, "error": "요약 파일을 읽지 못했습니다."]))
      }
      return .response(.json(["ok": true, "markdown": text]))

    case ("POST", "/api/title"):
      if let t = req.json(TitleRequest.self)?.title, !t.isEmpty {
        store.title = t
        autosave()
      }
      return .response(.json(["ok": true]))

    case ("POST", "/api/quit"):
      log("종료 요청을 받았습니다 — 정리를 시작합니다.")
      // 정리 중 어디가 막히더라도 프로세스는 반드시 죽는다.
      // 예전에는 정리가 걸리면 앱이 살아남아 "껐는데 안 꺼진다" 가 됐다.
      Self.armQuitWatchdog(seconds: 8)
      Task { await self.shutdown() }
      return .response(.json(["ok": true]))

    // ── 내보내기 ──
    case ("GET", "/export/srt"):
      return .response(.download(store.srt(), filename: "\(fileStem()).srt", type: "text/plain; charset=utf-8"))

    case ("GET", "/export/md"):
      return .response(.download(store.markdown(), filename: "\(fileStem()).md", type: "text/markdown; charset=utf-8"))


    default:
      return nil
    }
  }
}

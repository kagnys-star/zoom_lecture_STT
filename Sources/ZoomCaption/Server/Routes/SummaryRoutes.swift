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
      let request = req.json(SummarizeRequest.self)
      let fromUnit = request?.fromUnit
      let toUnit = request?.toUnit
      if let rangeError = summaryRangeValidationError(fromUnit: fromUnit, toUnit: toUnit) {
        return .response(.json(["ok": false, "error": rangeError]))
      }
      if stateLock.withLock({ running || stopping }) {
        return .response(.json(["ok": false,
                                "error": "녹음과 Whisper 정리가 끝난 뒤 요약해 주세요."]))
      }
      let units = store.lectureUnits(fromUnit: fromUnit, toUnit: toUnit)
      guard !units.isEmpty else {
        return .response(.json([
          "ok": false,
          "error": emptySummaryRangeMessage(fromUnit: fromUnit, toUnit: toUnit),
        ]))
      }
      guard case .ollama = await Summarizer.currentEngine() else {
        return .response(.json(["ok": false,
                                "error": "로컬 Qwen 요약이 설치되지 않았습니다. 프로젝트 폴더에서 `./setup-qwen.sh`를 실행하세요."]))
      }
      // 시작 시점의 세션을 작업에 새겨 둔다. 끝날 때 같은지 확인해야 그 사이 세션이
      // 바뀌었을 때 남의 수업 폴더에 이 요약을 적어 넣지 않는다.
      let job = SummaryJob(sessionDir: store.sessionDir)
      let claimed = stateLock.withLock { () -> Bool in
        guard activeSummaryJob == nil else { return false }
        activeSummaryJob = job
        return true
      }
      guard claimed else {
        return .response(.json(["ok": false, "error": "요약이 이미 진행 중입니다."]))
      }
      let rangeStart = fromUnit == nil ? nil : units.first?.start
      job.attach(Task { await self.runSummary(units: units, from: rangeStart, job: job) })
      return .response(.json(["ok": true]))

    case ("POST", "/api/summarize/cancel"):
      // generation을 올려 결과만 버리던 예전 방식은 모델을 계속 돌게 뒀다. 진짜 취소는
      // 진행 중인 Ollama 요청까지 끊어, 버릴 결과를 위해 8B 모델이 몇 분 더 도는 낭비를
      // 없앤다. 작업을 비우는 일은 runSummary의 defer가 한 곳에서 처리한다.
      guard let cancellingJob = stateLock.withLock({ activeSummaryJob }) else {
        return .response(.json(["ok": false, "error": "취소할 요약이 없습니다."]))
      }
      cancellingJob.cancel()
      log("요약 취소 요청 — 진행 중이던 로컬 요약을 끊습니다.")
      return .response(.json(["ok": true]))

    case ("GET", "/api/summary/units"):
      let units = store.lectureUnits()
      // 브라우저가 경계를 재구성하면 서버 Chunker가 바뀐 날 선택지와 실제 요약 범위가
      // 갈라질 수 있다. 서버가 확정한 id·시각만 보내 한 정의를 공유한다.
      let payload = units.map { unit in
        ["id": unit.id, "start": unit.start, "end": unit.end,
         "segmentCount": unit.segments.count] as [String: Any]
      }
      log("요약 구간 조회 — \(units.count)구간")
      return .response(.json(["ok": true, "units": payload]))

    case ("POST", "/api/summary/prompt"):
      let request = req.json(PromptRequest.self)
      let fromUnit = request?.fromUnit
      let toUnit = request?.toUnit
      if let rangeError = summaryRangeValidationError(fromUnit: fromUnit, toUnit: toUnit) {
        logWarn("프롬프트 내보내기 거부 — \(rangeError)")
        return .response(.json(["ok": false, "error": rangeError]))
      }
      // 온라인 경로는 Ollama도 모델 연산도 쓰지 않으므로 로컬 요약과 동시에 진행해도
      // 충돌하지 않는다. 입력 스냅샷이 계속 늘어나는 녹음·정리 중에만 막는다.
      if stateLock.withLock({ running || stopping }) {
        return .response(.json(["ok": false,
                                "error": "녹음과 Whisper 정리가 끝난 뒤 요약해 주세요."]))
      }
      let units = store.lectureUnits(fromUnit: fromUnit, toUnit: toUnit)
      guard !units.isEmpty else {
        let message = emptySummaryRangeMessage(fromUnit: fromUnit, toUnit: toUnit)
        logWarn("프롬프트 내보내기 거부 — \(message)")
        return .response(.json(["ok": false, "error": message]))
      }
      let target = PromptTarget(rawValue: request?.target ?? "") ?? .claude
      do {
        let bundle = try PromptExport.makeBundle(
          units: units,
          title: store.title,
          glossary: DomainKnowledge.glossary(store.domainTerms),
          target: target)
        log("프롬프트 내보내기 — 대상 \(target.displayName), 범위 "
          + "\(summaryRangeLabel(fromUnit: fromUnit, toUnit: toUnit)), "
          + "\(bundle.unitCount)구간, \(bundle.characterCount)자")
        return .response(.json([
          "ok": true,
          "text": bundle.text,
          "unitCount": bundle.unitCount,
          "chars": bundle.characterCount,
          "url": target.newChatURL,
          "targetName": target.displayName,
        ]))
      } catch {
        logWarn("프롬프트 내보내기 실패 — 대상 \(target.displayName), "
          + "\(error.localizedDescription)")
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    case ("POST", "/api/summary/import"):
      let request = req.json(SummaryImportRequest.self)
      let receivedMarkdown = request?.markdown ?? ""
      let fromUnit = request?.fromUnit
      let toUnit = request?.toUnit
      if let rangeError = summaryRangeValidationError(fromUnit: fromUnit, toUnit: toUnit) {
        logWarn("온라인 요약 거부 — 잘못된 범위 (수신 \(receivedMarkdown.count)자)")
        return .response(.json(["ok": false, "error": rangeError]))
      }
      if stateLock.withLock({ running || stopping }) {
        return .response(.json(["ok": false,
                                "error": "녹음과 Whisper 정리가 끝난 뒤 요약해 주세요."]))
      }
      // 사용자가 온라인 결과를 적용했는데 뒤늦게 끝난 로컬 요약이 그것을 덮어쓰면
      // "Claude로 만든 요약이 왜 사라졌지"가 된다. 방금 도착한 쪽이 사용자의 최신
      // 의사이므로 진행 중이던 로컬 요약을 끊는다.
      if let supersededJob = stateLock.withLock({ activeSummaryJob }) {
        supersededJob.cancel()
        log("온라인 요약이 도착해 진행 중이던 로컬 요약을 취소합니다.")
      }
      do {
        let result = try SummaryImport.validate(
          receivedMarkdown, expectedUnitCount: request?.expectedUnitCount ?? 0)
        let requestedTargetName = (request?.targetName ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = requestedTargetName.isEmpty ? "외부 LLM" : requestedTargetName
        // 문서가 자기 범위를 말하면 그것이 가장 강한 근거다. 헤딩이 깨졌을 때만
        // 온라인 작업의 구간 끝을 쓰고, 작업 맥락도 없는 파일이면 마지막 안전망으로
        // 전체 끝을 사용한다. 부분 요약을 무조건 전체 끝으로 기록하던 버그를 막는다.
        let hasOnlineJob = (request?.expectedUnitCount ?? 0) > 0
        let onlineJobUnits = hasOnlineJob
          ? store.lectureUnits(fromUnit: fromUnit, toUnit: toUnit) : []
        let fullTranscriptEnd = store.lectureUnits().last?.end
        let lastSummarizedAt = result.lastUnitEnd
          ?? onlineJobUnits.last?.end
          ?? fullTranscriptEnd
        applySummary(result.markdown,
                     lastSummarizedAt: lastSummarizedAt,
                     engineNote: "외부 LLM(수동 붙여넣기) · \(sourceName)",
                     from: onlineJobUnits.first?.start)
        log("온라인 요약 가져오기 — \(sourceName), 수신 \(receivedMarkdown.count)자, "
          + "\(result.unitCount)구간, 마지막 지점 "
          + "\(lastSummarizedAt.map(TranscriptStore.clock) ?? "-")")
        return .response(.json([
          "ok": true,
          "markdown": result.markdown,
          "warning": result.warning ?? "",
        ]))
      } catch SummaryImport.ImportError.exportedPrompt {
        logWarn("온라인 요약 거부 — 내보낸 프롬프트로 판정 (수신 \(receivedMarkdown.count)자)")
        return .response(.json([
          "ok": false,
          "error": SummaryImport.ImportError.exportedPrompt.localizedDescription,
        ]))
      } catch {
        logWarn("온라인 요약 거부 — \(error.localizedDescription) "
          + "(수신 \(receivedMarkdown.count)자)")
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

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

    // 시각이 없는 전사 원문. 외부 문장 교정(BERT 등)에 넘겼다가 그대로 되받는 파일이며,
    // 요약 프롬프트의 녹취 블록과 같은 렌더러를 쓴다 — 고쳐 돌려받은 문장이 곧 요약에
    // 들어가는 문장이라는 것이 이 공유로 보장된다.
    case ("GET", "/export/transcript.md"):
      let transcriptUnits = store.lectureUnits()
      guard !transcriptUnits.isEmpty else {
        logWarn("전사 문서 내보내기 거부 — 내보낼 Whisper 문장이 없습니다.")
        return .response(.json(["ok": false,
                                "error": "내보낼 Whisper 문장이 아직 없습니다."]))
      }
      let transcriptDocument = TranscriptDocument.file(units: transcriptUnits,
                                                      title: store.title)
      log("전사 문서 내보내기 — \(transcriptUnits.count)구간, "
        + "\(transcriptUnits.reduce(0) { $0 + $1.segments.count })줄, "
        + "\(transcriptDocument.count)자")
      return .response(.download(transcriptDocument,
        filename: "\(fileStem())_문장.md",
        type: "text/markdown; charset=utf-8"))

    case ("GET", "/export/prompt.md"):
      let target = PromptTarget(rawValue: req.query["target"] ?? "") ?? .claude
      let fromUnit = req.query["fromUnit"].flatMap(Int.init)
      let toUnit = req.query["toUnit"].flatMap(Int.init)
      if let rangeError = summaryRangeValidationError(fromUnit: fromUnit, toUnit: toUnit) {
        logWarn("프롬프트 파일 내보내기 거부 — \(rangeError)")
        return .response(.json(["ok": false, "error": rangeError]))
      }
      if stateLock.withLock({ running || stopping }) {
        return .response(.json(["ok": false,
                                "error": "녹음과 Whisper 정리가 끝난 뒤 요약해 주세요."]))
      }
      // 사용자가 온라인 결과를 적용했는데 뒤늦게 끝난 로컬 요약이 그것을 덮어쓰면
      // "Claude로 만든 요약이 왜 사라졌지"가 된다. 방금 도착한 쪽이 사용자의 최신
      // 의사이므로 진행 중이던 로컬 요약을 끊는다.
      if let supersededJob = stateLock.withLock({ activeSummaryJob }) {
        supersededJob.cancel()
        log("온라인 요약이 도착해 진행 중이던 로컬 요약을 취소합니다.")
      }
      let units = store.lectureUnits(fromUnit: fromUnit, toUnit: toUnit)
      guard !units.isEmpty else {
        let message = emptySummaryRangeMessage(fromUnit: fromUnit, toUnit: toUnit)
        logWarn("프롬프트 파일 내보내기 거부 — \(message)")
        return .response(.json(["ok": false, "error": message]))
      }
      do {
        let bundle = try PromptExport.makeBundle(
          units: units,
          title: store.title,
          glossary: DomainKnowledge.glossary(store.domainTerms),
          target: target)
        log("프롬프트 파일 내보내기 — 대상 \(target.displayName), 범위 "
          + "\(summaryRangeLabel(fromUnit: fromUnit, toUnit: toUnit)), "
          + "\(bundle.unitCount)구간, \(bundle.characterCount)자")
        return .response(.download(bundle.text,
          filename: "\(fileStem())_프롬프트.md",
          type: "text/markdown; charset=utf-8"))
      } catch {
        logWarn("프롬프트 파일 내보내기 실패 — 대상 \(target.displayName), "
          + "\(error.localizedDescription)")
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }


    default:
      return nil
    }
  }
}

/// 범위 문자열을 서버 로그와 사용자 오류에서 함께 써야 직접 호출과 UI 호출이 서로
/// 다른 표현을 남기지 않는다. nil은 브라우저 select의 처음/끝 기본값이다.
private func summaryRangeLabel(fromUnit: Int?, toUnit: Int?) -> String {
  switch (fromUnit, toUnit) {
  case (nil, nil): return "전체"
  case (let fromUnit?, nil): return "\(fromUnit)강~끝"
  case (nil, let toUnit?): return "처음~\(toUnit)강"
  case (let fromUnit?, let toUnit?) where fromUnit == toUnit: return "\(fromUnit)강"
  case (let fromUnit?, let toUnit?): return "\(fromUnit)강~\(toUnit)강"
  }
}

/// 낡은 탭이나 직접 API 호출은 브라우저 option의 disabled를 우회할 수 있으므로,
/// 역방향 범위는 실제 데이터를 읽기 전에 서버에서도 거부한다.
private func summaryRangeValidationError(fromUnit: Int?, toUnit: Int?) -> String? {
  guard let fromUnit, let toUnit, toUnit < fromUnit else { return nil }
  return "요약 종료 구간은 시작 구간보다 앞설 수 없습니다."
}

/// 범위가 비었을 때 선택한 id를 그대로 보여 줘야 사용자가 전체 전사 부재인지 특정
/// 구간 선택 오류인지 구분할 수 있다. 특히 직접 API 호출은 UI 힌트를 볼 수 없다.
private func emptySummaryRangeMessage(fromUnit: Int?, toUnit: Int?) -> String {
  if fromUnit == nil, toUnit == nil {
    return "Whisper 전사가 아직 준비되지 않았습니다."
  }
  return "\(summaryRangeLabel(fromUnit: fromUnit, toUnit: toUnit)) 구간에 Whisper 전사가 없습니다."
}

import Foundation
import AVFoundation
import AppKit

/// 수업 하나의 수명주기 — 세션 열기·만들기·저장, 녹음 시작·정지, 줄 편집.

extension ZoomCaptionApp {
  func sessionRoutes(_ req: HTTPRequest) async -> Route? {
    switch (req.method, req.path) {
    // ── 세션 ──
    case ("GET", "/api/sessions"):
      return .response(.json(["sessions": SessionStore.list(base: effectiveBaseDir, limit: 5)]))

    case ("POST", "/api/session/open"):
      guard let path = req.json(OpenRequest.self)?.path, !path.isEmpty else {
        return .response(.json(["ok": false, "error": "경로가 없습니다."]))
      }
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 다른 세션을 열 수 없습니다."]))
      }
      do {
        let dir = URL(fileURLWithPath: path)
        let file = try SessionStore.load(dir: dir)
        store.adopt(file, dir: dir)
        log("세션 이어받기: \(dir.lastPathComponent) (\(file.segments.count)개 발화, 이어쓰기 시작 \(TranscriptStore.clock(store.timeBase)))")
        return .response(.json(["ok": true, "state": await stateJSON()]))
      } catch {
        return .response(.json(["ok": false, "error": "세션을 읽을 수 없습니다: \(error.localizedDescription)"]))
      }

    case ("POST", "/api/session/new"):
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 새 세션을 만들 수 없습니다."]))
      }
      store.reset(title: "Zoom 수업")
      return .response(.json(["ok": true, "state": await stateJSON()]))

    case ("POST", "/api/session/delete"):
      guard let path = req.json(OpenRequest.self)?.path, !path.isEmpty else {
        return .response(.json(["ok": false, "error": "경로가 없습니다."]))
      }
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 지울 수 없습니다."]))
      }
      if path == store.sessionDir?.path {
        return .response(.json(["ok": false, "error": "지금 열려 있는 세션은 지울 수 없습니다. 다른 세션으로 전환한 뒤 지워 주세요."]))
      }
      let dir = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(SessionStore.jsonName).path) else {
        return .response(.json(["ok": false, "error": "세션 폴더가 아닙니다."]))
      }
      do {
        // 완전 삭제(removeItem) 대신 휴지통 — 원본 강의 음성이 같이 들어있어 복구 가능한 쪽을 쓴다.
        try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        return .response(.json(["ok": true]))
      } catch {
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    case ("POST", "/api/pickFolder"):
      // osascript 를 띄우고 사용자가 고를 때까지 기다린다. 메인 스레드를 막지 않도록 분리 실행.
      let start = store.sessionDir?.deletingLastPathComponent() ?? effectiveBaseDir
      let picked = await Task.detached { SessionStore.pickFolder(startingAt: start) }.value
      return .response(.json(["ok": picked != nil, "path": picked ?? ""]))

    case ("POST", "/api/settings/storageLocation"):
      guard let path = req.json(OpenRequest.self)?.path, !path.isEmpty else {
        return .response(.json(["ok": false, "error": "경로가 없습니다."]))
      }
      StorageLocation.current = URL(fileURLWithPath: path)
      return .response(.json(["ok": true]))

    case ("POST", "/api/save"):
      do {
        try ensureSessionDir()
        let dir = try SessionStore.save(store)
        return .response(.json(["ok": true, "path": dir?.path ?? ""]))
      } catch {
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    // ── 녹음 ──
    case ("POST", "/api/start"):
      let r = req.json(StartRequest.self) ?? StartRequest()
      // 자리를 **먼저** 잡고 시작한다.
      // 예전에는 start() 끝에서 running 을 세워서, 그 사이 몇 초 동안 두 번째 요청이
      // 그대로 통과했다. 그러면 오디오 아카이브도 Whisper 워커도 두 벌이 돌고
      // 세션 폴더는 나중 것으로 덮여, 먼저 것은 아무도 안 보는 폴더에 계속 쓴다.
      let claimed = stateLock.withLock { () -> Bool in
        if running || starting || stopping { return false }
        starting = true
        running = true
        return true
      }
      guard claimed else {
        logWarn("이미 녹음 중인데 시작 요청이 또 들어왔습니다 — 무시합니다.")
        return .response(.json(["ok": false, "error": "이미 녹음 중입니다.",
                                "state": await stateJSON()]))
      }
      log("시작 요청 — \(r.title ?? "제목 없음")")
      do {
        try await start(title: r.title,
                        terms: r.terms ?? [],
                        folder: r.folder,
                        baseDir: r.baseDir,
                        keepAudio: r.keepAudio ?? true)
        stateLock.withLock { starting = false }
        return .response(.json(["ok": true, "state": await stateJSON()]))
      } catch {
        // 잡아둔 자리를 반드시 놓아준다. 안 그러면 다시는 시작할 수 없다.
        stateLock.withLock { running = false; starting = false }
        live.broadcast(event: "status", payload: ["running": false])
        logError("녹음 시작 실패: \(error)")
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    case ("POST", "/api/stop"):
      let saved = await stop()
      return .response(.json(["ok": true, "saved": saved ?? "", "state": await stateJSON()]))

    // ── 편집 ──
    //
    // 녹음 중에는 편집을 막는다. Whisper 가 뒤에서 계속 줄을 추가·재배치하는 중에
    // 사용자가 같은 줄을 고치면 어느 쪽이 이기는지 애매해지고, 문단화(Paragraph.swift)가
    // 이미 벡터를 캐시해 둔 문장의 내용이 바뀌면 그 캐시만 조용히 낡는다.
    case ("POST", "/api/segment/update"):
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 편집할 수 없습니다. 정지한 뒤 고쳐 주세요."]))
      }
      guard let r = req.json(EditRequest.self), let id = r.id else {
        return .response(.json(["ok": false, "error": "잘못된 요청"]))
      }
      let ok = r.list == "whisper"
        ? store.updateWhisperSegment(id: id, text: r.text ?? "")
        : store.updateSegment(id: id, text: r.text ?? "")
      autosave()
      return .response(.json(["ok": ok]))

    case ("POST", "/api/segment/delete"):
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 편집할 수 없습니다. 정지한 뒤 지워 주세요."]))
      }
      guard let r = req.json(DeleteRequest.self) else {
        return .response(.json(["ok": false, "error": "잘못된 요청"]))
      }
      var removed = 0
      if let ids = r.ids, !ids.isEmpty {
        removed = r.list == "whisper" ? store.deleteWhisperSegments(ids: ids)
                                      : store.deleteSegments(ids: ids)
      } else if let from = r.from, let to = r.to { removed = store.deleteRange(from: from, to: to) }
      autosave()
      return .response(.json(["ok": true, "removed": removed]))


    default:
      return nil
    }
  }
}

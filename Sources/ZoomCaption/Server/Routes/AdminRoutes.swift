import Foundation
import AVFoundation
import AppKit

/// 관리자 모드 전용 — 저장된 소리를 파이프라인에 되먹이기, 무음 위에 적힌 줄 점검.
///
/// 둘 다 `--admin` 또는 `ZOOMCAPTION_ADMIN=1` 일 때만 연다.
/// 수업이 있어야만 확인할 수 있던 것들을 수업 없이 확인하려고 만들었다.

extension ZoomCaptionApp {
  func adminRoutes(_ req: HTTPRequest) async -> Route? {
    switch (req.method, req.path) {
    // ── 무음 의심 검사 ──
    //
    // Whisper 가 무음 구간에서 지어낸 문장을 찾는다. **지우지는 않는다** —
    // 표본이 아직 환각 6건뿐이라, 우선 표시만 해서 오탐이 정말 없는지 확인하는 단계다.
    case ("GET", "/api/quiet"):
      // Whisper 가 VAD 로 무음을 아예 안 읽으므로 평소에는 나올 게 없다.
      // 그래서 **관리자 모드에서 점검용으로만** 연다 — VAD 가 도는지 확인하는 계기판이다.
      guard options.admin else {
        return .response(.json(["ok": false,
          "error": "관리자 모드에서만 씁니다. Whisper 가 VAD 로 무음을 거르므로 평소에는 필요 없습니다."]))
      }
      guard let dir = store.sessionDir else {
        return .response(.json(["ok": false, "error": "세션 폴더가 없습니다. 먼저 저장하세요."]))
      }
      guard !AudioArchive.clips(in: dir).isEmpty else {
        return .response(.json(["ok": true, "hasAudio": false, "items": []]))
      }
      var items: [[String: Any]] = []
      var measured = 0
      for seg in store.whisperSegments {
        guard let db = AudioSlice.peakDBFS(dir: dir, from: seg.start, to: seg.end) else { continue }
        measured += 1
        guard db < AudioSlice.quietCeiling else { continue }
        // 두 번째 신호 — 같은 시각에 실시간 기록이 있었는가.
        // 실시간 전사기는 침묵을 침묵으로 두므로, 거기 글이 있다는 건 말이 있었다는 뜻이다.
        let near = store.liveTextNear(start: seg.start, end: seg.end)
        let match = Alignment.longestCommon(seg.text, near)
        items.append([
          "id": seg.id, "start": seg.start, "end": seg.end, "text": seg.text, "db": db,
          "liveMatch": match,
          // 소리도 없고 실시간 대응도 없으면 거의 확실하다. 하나만이면 사람이 본다.
          "verdict": match < Self.liveSupportChars ? "certain" : "suspect",
        ])
      }
      // 결과는 로그로도 남긴다. 화면을 안 봐도 나중에 추적할 수 있어야 한다.
      if items.isEmpty {
        log("무음 점검 — \(measured)줄 대조, 걸린 것 없음 (VAD 정상)")
      } else {
        logWarn("무음 점검 — \(measured)줄 중 \(items.count)줄이 무음 위에 적혀 있습니다. "
              + "VAD 가 안 돌고 있을 수 있습니다.")
        for it in items {
          let t = TranscriptStore.clock(it["start"] as? Double ?? 0)
          let db = it["db"] as? Double ?? 0
          logWarn("  \(t) \(String(format: "%.1f", db))dBFS "
                + "겹침\(it["liveMatch"] as? Int ?? 0)자 「\(it["text"] as? String ?? "")」")
        }
      }
      return .response(.json([
        "ok": true, "hasAudio": true,
        "checked": measured, "total": store.whisperSegments.count,
        "ceiling": AudioSlice.quietCeiling,
        "supportChars": Self.liveSupportChars,
        "hasLive": !store.allSegments.isEmpty,
        "dropped": store.droppedQuiet.count,
        "items": items,
      ]))

    // 확실한 것만 한 번에 치운다. **지우는 게 아니라 옆에 치워 두고 되돌릴 수 있게 한다.**
    case ("POST", "/api/quiet/clean"):
      guard let ids = req.json(QuietCleanRequest.self)?.ids, !ids.isEmpty else {
        return .response(.json(["ok": false, "error": "치울 줄이 없습니다."]))
      }
      let n = store.dropQuiet(ids: ids)
      if n > 0 { autosave() }
      log("무음 의심 \(n)줄을 치웠습니다 (되돌릴 수 있음)")
      return .response(.json(["ok": true, "dropped": n, "state": await stateJSON()]))

    case ("POST", "/api/quiet/restore"):
      let n = store.restoreQuiet()
      if n > 0 { autosave() }
      log("치워 둔 무음 의심 \(n)줄을 되돌렸습니다")
      return .response(.json(["ok": true, "restored": n, "state": await stateJSON()]))

    // ── 관리자 모드 ──
    //
    // Zoom 이 실제로 소리를 내야만 아무것도 확인할 수 없다는 게 이 앱의 가장 큰 제약이었다.
    // 저장된 WAV 를 같은 파이프라인에 되먹이면 수업 없이도 끝까지 시험할 수 있다.
    case ("GET", "/api/admin"):
      return .response(.json([
        "enabled": options.admin,
        "feeding": adminFeed.isRunning,
        "note": adminFeed.note,
        "clips": store.sessionDir.map { dir in
          AudioArchive.clips(in: dir).map {
            ["name": $0.url.lastPathComponent, "path": $0.url.path,
             "start": $0.startOffset, "bytes": $0.bytes] as [String: Any]
          }
        } ?? [],
      ]))

    case ("POST", "/api/admin/feed"):
      guard options.admin else {
        return .response(.json(["ok": false,
          "error": "관리자 모드가 꺼져 있습니다. --admin 또는 ZOOMCAPTION_ADMIN=1 로 실행하세요."]))
      }
      guard let r = req.json(AdminFeedRequest.self), let path = r.path, !path.isEmpty else {
        return .response(.json(["ok": false, "error": "소리 파일 경로가 없습니다."]))
      }
      let feedURL = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: feedURL.path) else {
        return .response(.json(["ok": false, "error": "그 경로에 파일이 없습니다: \(path)"]))
      }
      // 녹음이 안 돌고 있으면 먼저 켠다 — 되먹임만으로는 전사기가 서 있지 않다.
      if !stateLock.withLock({ running }) {
        let claimed = stateLock.withLock { () -> Bool in
          guard !running, !starting, !stopping else { return false }
          running = true
          starting = true
          adminFeedPending = true
          return true
        }
        guard claimed else {
          return .response(.json(["ok": false, "error": "녹음 상태가 바뀌는 중입니다. 잠시 뒤 다시 시도하세요."]))
        }
        do { try await start(title: r.title ?? "관리자 시험", terms: [],
                             folder: nil, baseDir: nil, keepAudio: true)
          stateLock.withLock { starting = false }
        }
        catch {
          stateLock.withLock { running = false; starting = false; adminFeedPending = false }
          return .response(.json(["ok": false,
            "error": "시작하지 못했습니다: \(error.localizedDescription)"]))
        }
      }
      guard let sink = audioSink else {
        return .response(.json(["ok": false, "error": "오디오 받개가 준비되지 않았습니다."]))
      }
      do {
        try adminFeed.start(url: feedURL, speed: r.speed ?? 1.0, onBuffer: sink,
                            onFinish: { [weak self] why in
                              self?.live.broadcast(event: "adminFeed",
                                                   payload: ["done": true, "why": why])
                            })
      } catch {
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }
      return .response(.json(["ok": true, "note": adminFeed.note]))

    case ("POST", "/api/admin/feed/stop"):
      adminFeed.stop()
      return .response(.json(["ok": true]))


    default:
      return nil
    }
  }
}

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
      let currentAudioProbePayload: Any = administratorAudioProbe.snapshot().map {
        administratorAudioProbePayload($0) as Any
      } ?? NSNull()
      return .response(.json([
        "enabled": options.admin,
        "feeding": adminFeed.isRunning,
        "note": adminFeed.note,
        "audioProbe": currentAudioProbePayload,
        "clips": store.sessionDir.map { dir in
          AudioArchive.clips(in: dir).map {
            ["name": $0.url.lastPathComponent, "path": $0.url.path,
             "start": $0.startOffset, "bytes": $0.bytes] as [String: Any]
          }
        } ?? [],
      ]))

    // ── 관리자 실제 탭 A/B probe ──
    // 운영 녹음에 들어갈 resolver를 미리 확정하지 않고, 현재 HAL이 노출하는 Zoom
    // 프로세스·출력 장치·스트림 후보와 각 후보의 PCM 활동만 독립적으로 측정한다.
    case ("GET", "/api/admin/audio/probe/candidates"):
      guard options.admin else {
        return .response(.json(["ok": false, "error": "관리자 모드에서만 사용할 수 있습니다."]))
      }
      let zoomRelatedAudioProcesses = CoreAudioInfo.processes().filter {
        // `contains("zoom")`은 이 앱의 `com.local.zoomcaption`까지 후보로 넣는다.
        // Zoom 데스크톱 앱 계열의 실제 번들 네임스페이스만 열어 A/B 목록 자체가
        // 다른 프로세스의 소리를 잘못 측정하도록 유도하지 않게 한다.
        $0.bundleID.lowercased().hasPrefix("us.zoom.")
      }
      let processPayloads: [[String: Any]] = zoomRelatedAudioProcesses.map { audioProcess in
        let outputDevicePayloads: [[String: Any]] = CoreAudioInfo.outputDevices(
          usedBy: audioProcess).map { outputDevice in
            [
              "objectID": outputDevice.objectID,
              "uid": outputDevice.uid,
              "name": outputDevice.name,
              "streams": outputDevice.streams.map { outputStream in
                [
                  "index": outputStream.streamIndex,
                  "objectID": outputStream.objectID,
                ] as [String: Any]
              },
            ] as [String: Any]
          }
        return [
          "objectID": audioProcess.objectID,
          "pid": audioProcess.pid,
          "bundleID": audioProcess.bundleID,
          "hasActiveOutputIO": CoreAudioInfo.hasActiveOutputIO(audioProcess),
          "currentlyAllowlisted": SystemAudioTap.zoomBundleIDs.contains(audioProcess.bundleID),
          "outputDevices": outputDevicePayloads,
        ]
      }
      return .response(.json(["ok": true, "processes": processPayloads]))

    case ("POST", "/api/admin/audio/probe/start"):
      guard options.admin else {
        return .response(.json(["ok": false, "error": "관리자 모드에서만 사용할 수 있습니다."]))
      }
      // probe와 실제 관리자 녹음을 동시에 돌리면 어느 탭이 만든 레벨인지 사람이
      // 혼동하기 쉽다. 데이터 격리뿐 아니라 해석 격리를 위해 녹음 중에는 시작하지 않는다.
      guard !stateLock.withLock({ running || starting || stopping }) else {
        return .response(.json([
          "ok": false,
          "error": "녹음을 정지한 뒤 A/B probe를 실행해 주세요.",
        ]))
      }
      guard let request = req.json(AdministratorAudioProbeStartRequest.self),
            let requestedProcessObjectID = request.processObjectID,
            let selectedProcess = CoreAudioInfo.processes().first(where: {
              $0.objectID == requestedProcessObjectID
            })
      else {
        return .response(.json(["ok": false, "error": "유효한 오디오 프로세스를 선택해 주세요."]))
      }

      let normalizedDeviceUID = request.deviceUID?.trimmingCharacters(in: .whitespacesAndNewlines)
      let requestedDeviceUID = normalizedDeviceUID?.isEmpty == false ? normalizedDeviceUID : nil
      guard (requestedDeviceUID == nil) == (request.streamIndex == nil) else {
        return .response(.json([
          "ok": false,
          "error": "장치와 스트림 순번은 함께 지정하거나 둘 다 비워야 합니다.",
        ]))
      }

      var selectedDeviceName: String?
      var selectedStreamObjectID: AudioStreamID?
      if let requestedDeviceUID, let requestedStreamIndex = request.streamIndex {
        guard let selectedOutputDevice = CoreAudioInfo.outputDevices(usedBy: selectedProcess)
          .first(where: { $0.uid == requestedDeviceUID }),
          let selectedOutputStream = selectedOutputDevice.streams.first(where: {
            $0.streamIndex == requestedStreamIndex
          })
        else {
          return .response(.json([
            "ok": false,
            "error": "선택한 장치·스트림이 현재 이 프로세스의 출력 경로에 없습니다.",
          ]))
        }
        selectedDeviceName = selectedOutputDevice.name
        selectedStreamObjectID = selectedOutputStream.objectID
      }

      let probeSelection = AdministratorAudioProbeSelection(
        process: selectedProcess,
        deviceUID: requestedDeviceUID,
        deviceName: selectedDeviceName,
        streamIndex: request.streamIndex,
        streamObjectID: selectedStreamObjectID)
      do {
        let initialSnapshot = try administratorAudioProbe.start(selection: probeSelection)
        return .response(.json([
          "ok": true,
          "probe": administratorAudioProbePayload(initialSnapshot),
        ]))
      } catch {
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    case ("GET", "/api/admin/audio/probe"):
      guard options.admin else {
        return .response(.json(["ok": false, "error": "관리자 모드에서만 사용할 수 있습니다."]))
      }
      guard let currentSnapshot = administratorAudioProbe.snapshot() else {
        return .response(.json(["ok": true, "running": false]))
      }
      return .response(.json([
        "ok": true,
        "running": true,
        "probe": administratorAudioProbePayload(currentSnapshot),
      ]))

    case ("POST", "/api/admin/audio/probe/stop"):
      guard options.admin else {
        return .response(.json(["ok": false, "error": "관리자 모드에서만 사용할 수 있습니다."]))
      }
      let finalSnapshot = administratorAudioProbe.stop()
      let finalProbePayload: Any = finalSnapshot.map {
        administratorAudioProbePayload($0) as Any
      } ?? NSNull()
      return .response(.json([
        "ok": true,
        "running": false,
        "probe": finalProbePayload,
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

  /// A/B 시작·조회·정지가 같은 JSON 모양을 쓰게 한다. 피크가 한 번도 없으면
  /// `-infinity`인데 JSON은 비유한 부동소수점을 표현하지 못하므로 -120dBFS로 제한한다.
  private func administratorAudioProbePayload(
    _ snapshot: AdministratorAudioCaptureProbe.Snapshot
  ) -> [String: Any] {
    [
      "bundleID": snapshot.selection.process.bundleID,
      "pid": snapshot.selection.process.pid,
      "processObjectID": snapshot.selection.process.objectID,
      "deviceUID": snapshot.selection.deviceUID ?? NSNull(),
      "deviceName": snapshot.selection.deviceName ?? NSNull(),
      "streamIndex": snapshot.selection.streamIndex ?? NSNull(),
      "streamObjectID": snapshot.selection.streamObjectID ?? NSNull(),
      "sourceFormat": snapshot.sourceFormatDescription,
      "elapsedSeconds": snapshot.elapsedSeconds,
      "secondsSinceBuffer": snapshot.secondsSinceMostRecentBuffer ?? NSNull(),
      "bufferCount": snapshot.audioBufferCount,
      "frameCount": snapshot.observedFrameCount,
      "peakDBFS": snapshot.peakDBFS.isFinite ? snapshot.peakDBFS : -120,
      "rms": snapshot.rmsLevel,
      "nonSilentBufferRatio": snapshot.nonSilentBufferRatio,
    ]
  }
}

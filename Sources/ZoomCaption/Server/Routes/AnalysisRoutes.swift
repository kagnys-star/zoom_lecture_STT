import Foundation
import AVFoundation
import AppKit

/// 두 기록(실시간·Whisper)을 견주는 일 전부 —
/// 정렬 통계, 본문에서 바로 고치기, 되돌리기, 정답지 표본 모으기.

extension ZoomCaptionApp {
  func analysisRoutes(_ req: HTTPRequest) async -> Route? {
    switch (req.method, req.path) {
    // ── 정렬·대조 ──
    case ("GET", "/api/compare"):
      let live = store.allSegments, whisper = store.whisperSegments
      // 녹음 중에는 Whisper 가 아직 안 따라온 뒤쪽을 비교하면 안 된다.
      // 정지한 뒤에는 볼 것을 다 봤으니 제한을 푼다.
      let recording = stateLock.withLock { running }
      let settled = recording ? Alignment.settledUntil(live: live, whisper: whisper) : .infinity
      let blocks = Alignment.compareWindowed(live: live, whisper: whisper, until: settled)
      var json = Alignment.summary(blocks)
      // 통계만 필요할 때는 블록을 싣지 않는다. 긴 강의는 블록이 3,300개라 응답이 776KB 가 되고,
      // 그걸 화면에 그리면 DOM 노드 4,000개를 먹는다. 갈린 자리는 본문 밑줄이 이미 보여 준다.
      if req.query["stats"] == "1" {
        json["hasBoth"] = !live.isEmpty && !whisper.isEmpty
        json["settledUntil"] = settled.isFinite ? settled : -1
        return .response(.json(json))
      }
      json["blocks"] = blocks.map { b in
        // 표본 판정에는 **원문 그대로**(공백·대소문자 포함)를 보여줘야 한다.
        // 정규화된 글자를 보여주면 사람도 모델처럼 엉뚱한 걸 고르게 된다.
        ["kind": b.kind.rawValue, "live": b.live, "whisper": b.whisper,
         "liveRaw": b.liveRaw.isEmpty ? b.live : b.liveRaw,
         "whisperRaw": b.whisperRaw.isEmpty ? b.whisper : b.whisperRaw,
         // 본문에서 고치려면 원문 어디인지 알아야 한다.
         "segID": b.segID, "rangeStart": b.rangeStart, "rangeEnd": b.rangeEnd,
         "mark": b.worthAsking(),
         "start": b.start, "end": b.end,
         "key": "\(Int((b.start * 10).rounded()))|\(b.live)|\(b.whisper)"] as [String: Any]
      }
      json["hasBoth"] = !live.isEmpty && !whisper.isEmpty
      json["hasAudio"] = store.sessionDir.map { !AudioArchive.clips(in: $0).isEmpty } ?? false
      json["settledUntil"] = settled.isFinite ? settled : -1     // -1 = 제한 없음
      return .response(.json(json))

    // ── 본문에서 바로 고치기 ──
    //
    // 갈린 자리에 밑줄을 긋고, 눌러서 실시간 쪽 표기를 보고, 골라서 고친다.
    // 사용자가 어차피 하는 일(복습하며 읽기) 위에 얹히기 때문에 따로 드는 시간이 없다.
    case ("POST", "/api/fix"):
      // 편집과 같은 이유로 녹음 중엔 막는다(SessionRoutes.swift 의 "편집" 절 참고) —
      // 여기서 고치는 것도 결국 whisperSegments 의 text 를 바꾸는 일이라 위험이 같다.
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 편집할 수 없습니다. 정지한 뒤 고쳐 주세요."]))
      }
      guard let r = req.json(FixRequest.self) else {
        return .response(.json(["ok": false, "error": "고칠 내용을 읽지 못했습니다."]))
      }
      let after = r.after.trimmingCharacters(in: .whitespacesAndNewlines)
      // "원안이 맞다" 는 고칠 게 없다. 그래도 표본으로는 값어치가 있어 기록은 남긴다.
      var changed = false
      if r.verdict != "whisper", !after.isEmpty, after != r.before {
        changed = store.applyCorrection(segID: r.segID, rangeStart: r.rangeStart,
                                        rangeEnd: r.rangeEnd, before: r.before, after: after)
        if !changed {
          // 그 사이에 본문이 바뀌었다는 뜻이다. 엉뚱한 자리를 덮어쓰느니 멈춘다.
          return .response(.json(["ok": false,
            "error": "그 자리의 글이 바뀌어 고치지 못했습니다. 새로 고친 뒤 다시 눌러 주세요."]))
        }
      }
      // 판정을 정답지에 남긴다. 여기서 넘기는 건 **전부 원문 그대로**다.
      if let dir = store.sessionDir, let start = r.start {
        var set = GoldSet.load(from: dir)
        set.put(GoldSample(start: start, end: r.end ?? (start + 3),
                           kind: r.kind ?? "differ",
                           live: r.live ?? "", whisper: r.before,
                           truth: r.verdict == "whisper" ? r.before : after,
                           verdict: r.verdict, at: Date(), schema: 2,
                           segID: r.segID, rangeStart: r.rangeStart, rangeEnd: r.rangeEnd))
        set.save(to: dir)
      }
      if changed { autosave() }
      return .response(.json(["ok": true, "changed": changed, "state": await stateJSON()]))

    // ── 교정 되돌리기 ──
    // 본문에서 직접 고친 것을 원래대로 돌린다.
    case ("POST", "/api/correct/revert"):
      // 되돌리기도 text 를 바꾸는 편집의 일종이라 같은 이유로 막는다.
      if stateLock.withLock({ running }) {
        return .response(.json(["ok": false, "error": "녹음 중에는 편집할 수 없습니다. 정지한 뒤 되돌려 주세요."]))
      }
      let n = store.revertCorrections()
      autosave()
      log("문맥 교정 되돌림 — \(n)줄 복원")
      return .response(.json(["ok": true, "reverted": n, "state": await stateJSON()]))

    // ── 표본 모으기 ──
    //
    // 소리를 들려주고, 갈린 자리에서 어느 쪽이 맞는지만 고르게 한다.
    // 받아쓰기가 아니라 고르기라 한 지점에 몇 초면 끝난다.

    case ("GET", "/api/audio"):
      guard let dir = store.sessionDir else { return .response(.notFound) }
      let from = Double(req.query["from"] ?? "") ?? 0
      let to = Double(req.query["to"] ?? "") ?? (from + 3)
      guard let data = AudioSlice.wav(dir: dir, from: from, to: to) else {
        return .response(HTTPResponse(status: 404, body: Data("소리 없음".utf8)))
      }
      // 3초 조각이 96KB 라 루프백에서 매번 새로 받아도 부담이 없다.
      return .response(HTTPResponse(contentType: "audio/wav", body: data))

    case ("GET", "/api/gold"):
      return .response(.json(goldJSON()))

    case ("POST", "/api/gold"):
      guard let dir = store.sessionDir else {
        return .response(.json(["ok": false, "error": "세션 폴더가 없습니다. 먼저 저장하세요."]))
      }
      guard let r = req.json(GoldRequest.self), let start = r.start,
            let verdict = r.verdict else {
        return .response(.json(["ok": false, "error": "표본 내용이 모자랍니다."]))
      }
      let live = r.live ?? "", whisper = r.whisper ?? ""
      // 판정에 따라 정답을 정한다. 둘 다 틀렸을 때만 사람이 직접 적는다.
      let truth: String
      switch verdict {
      case "live": truth = live
      case "whisper": truth = whisper
      case "both":
        let typed = (r.truth ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
          return .response(.json(["ok": false, "error": "둘 다 틀렸다면 실제 내용을 적어야 합니다."]))
        }
        truth = typed
      default: truth = ""            // unclear — 넘긴 것
      }
      var set = GoldSet.load(from: dir)
      set.put(GoldSample(start: start, end: r.end ?? (start + 3), kind: r.kind ?? "differ",
                         live: live, whisper: whisper, truth: truth,
                         verdict: verdict, at: Date(), schema: 2))
      set.save(to: dir)
      return .response(.json(goldJSON()))

    case ("POST", "/api/gold/delete"):
      guard let dir = store.sessionDir, let key = req.json(GoldRequest.self)?.key else {
        return .response(.json(["ok": false, "error": "지울 표본을 찾지 못했습니다."]))
      }
      var set = GoldSet.load(from: dir)
      set.remove(key: key)
      set.save(to: dir)
      return .response(.json(goldJSON()))

    case ("GET", "/api/gold/all"):
      // 수업이 쌓일수록 이 숫자가 믿을 만해진다.
      let all = GoldScore.collectAll(baseDir: options.baseDir)
      let flat = all.flatMap(\.samples)
      return .response(.json([
        "sessions": all.map { ["name": $0.session, "count": $0.samples.count] },
        "score": GoldScore.summary(flat),
      ]))

    default:
      return nil
    }
  }
}

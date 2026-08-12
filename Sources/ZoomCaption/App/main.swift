import Foundation
import AVFoundation
import AppKit

// MARK: - 설정

struct Options {
  var port: UInt16 = 8765
  var localeID = "ko-KR"
  var openBrowser = true
  /// 관리자 모드. Zoom 없이 시험할 수 있게 두 가지를 연다 —
  /// ① 시스템 전체 오디오 캡처(Zoom 만이 아니라), ② 저장된 WAV 를 파이프라인에 직접 되먹임.
  /// `--admin` 또는 `ZOOMCAPTION_ADMIN=1`.
  var admin = false
  var baseDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/ZoomCaption", isDirectory: true)

  static func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--port": if i + 1 < args.count, let p = UInt16(args[i + 1]) { o.port = p; i += 1 }
      case "--locale": if i + 1 < args.count { o.localeID = args[i + 1]; i += 1 }
      case "--dir": if i + 1 < args.count { o.baseDir = URL(fileURLWithPath: args[i + 1]); i += 1 }
      case "--no-open": o.openBrowser = false
      case "--admin": o.admin = true
      default: break
      }
      i += 1
    }
    if ProcessInfo.processInfo.environment["ZOOMCAPTION_ADMIN"] == "1" { o.admin = true }
    return o
  }
}

struct StartRequest: Decodable {
  var title: String?
  var terms: [String]?
  /// 세션 폴더 이름. 이어 적기 중이면 무시된다.
  var folder: String?
  /// 세션 폴더를 만들 상위 위치. 비우면 기본 저장 위치.
  var baseDir: String?
  /// 소리도 WAV 로 남길지. 나중에 재전사하려면 필요하다.
  var keepAudio: Bool?
}
struct TitleRequest: Decodable { var title: String? }
struct OpenRequest: Decodable { var path: String? }
/// `list` 가 "whisper" 면 Whisper 기록을, 아니면 실시간 기록을 고친다.
struct EditRequest: Decodable { var id: Int?; var text: String?; var list: String? }
struct DeleteRequest: Decodable { var ids: [Int]?; var from: Double?; var to: Double?; var list: String? }
struct SummarizeRequest: Decodable { var from: Double? }
struct SaveSummaryRequest: Decodable { var dir: String?; var filename: String? }
struct ApplyCorrectionsRequest: Decodable {
  struct Item: Decodable { var segID: Int; var rangeStart: Int; var rangeEnd: Int
                           var before: String; var after: String }
  var items: [Item]?
}
struct GoldRequest: Decodable {
  var start: Double?; var end: Double?; var kind: String?
  var live: String?; var whisper: String?
  var truth: String?; var verdict: String?
  var key: String?          // 삭제할 때만
}

struct QuietCleanRequest: Decodable { var ids: [Int]? }

struct AdminFeedRequest: Decodable {
  var path: String?
  var speed: Double?
  var title: String?
}

/// 본문에서 갈린 자리를 바로 고칠 때 오는 요청.
///
/// 고치는 행위 하나가 두 가지 일을 한다 — 기록을 바로잡고, **정답지 표본을 남긴다.**
/// 그래서 표본을 모으려고 따로 시간을 낼 필요가 없다.
struct FixRequest: Decodable {
  var segID: Int
  var rangeStart: Int
  var rangeEnd: Int
  var before: String        // 지금 본문에 있는 글자 (원문 그대로)
  var after: String         // 바꿔 넣을 글자
  var verdict: String       // live | whisper | both — whisper 는 "원안이 맞다"
  var start: Double?
  var end: Double?
  var kind: String?
  var live: String?         // 실시간 쪽 원문 (표본에 남긴다)
}

// MARK: - 앱

final class ZoomCaptionApp: @unchecked Sendable {
  private let options: Options
  private let store = TranscriptStore()
  private let server: HTTPServer
  /// 기본 포트가 막혀 다른 포트로 열었을 때 실제로 쓰는 서버
  private var activeServer: HTTPServer?
  /// 브로드캐스트·종료는 반드시 실제로 열린 서버로 가야 한다
  private var live: HTTPServer { activeServer ?? server }
  /// 실제로 열린 웹 UI 주소. 앱을 다시 실행했을 때 이 주소를 다시 연다.
  private(set) var webURL: URL?

  private var tap: SystemAudioTap?
  /// 관리자 되먹임. 저장된 WAV 를 실제 탭과 **같은 닫힘**에 밀어 넣어 전체 경로를 시험한다.
  private let adminFeed = AdminFeed()
  /// 지금 녹음이 쓰는 오디오 받개. 되먹임이 여기로 들어간다.
  private var audioSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
  /// 이번 시작은 탭 없이(되먹임으로) 간다는 표시
  private var adminFeedPending = false

  /// 무음 의심 줄이 "진짜 말이었다" 고 볼 최소 근거 — 실시간 기록과 겹치는 글자 수.
  ///
  /// 실측(환각 5건 대 진짜 2건)에서 이 값으로 깨끗하게 갈렸다:
  /// 환각은 0·1·2·2·0자, 진짜는 7자·51자. 비율로 재면 안 된다 —
  /// 「감사합니다」는 5자뿐이라 2자만 우연히 겹쳐도 40%가 된다.
  static let liveSupportChars = 5

  private var lectureTranscriber: TrackTranscriber?
  /// 이번 녹음 구간의 소리를 담는 WAV. 나중에 재전사·확인에 쓴다.
  private var archive: AudioArchive?
  /// 수업이 도는 동안 뒤에서 Whisper 를 돌리는 워커
  private var whisperLive: WhisperLive?
  /// 실시간 재전사가 안 돌고 있다면 그 이유. 위 칸이 왜 비어 있는지 화면에 그대로 띄운다.
  private var whisperLiveNote: String?
  private var silenceWatchdog: DispatchSourceTimer?

  private let stateLock = NSLock()
  private var running = false
  private var resolvedLocale: Locale?
  private var analyzerFormat: AVAudioFormat?
  private var userTerms: [String] = []
  /// 세션 폴더가 생기기 전에 올라온 교안 PDF
  private var pendingDomainPDF: (name: String, url: URL)?

  init(options: Options) {
    self.options = options
    self.server = HTTPServer(port: options.port)
  }

  func boot() throws {
    logEnvironment()
    try? FileManager.default.createDirectory(at: options.baseDir, withIntermediateDirectories: true)

    store.onChange = { [weak self] event in
      guard let self else { return }
      switch event {
      case .final(let seg):
        self.live.broadcast(event: "segment", payload: [
          "id": seg.id, "track": seg.track.rawValue,
          "start": seg.start, "end": seg.end, "text": seg.text,
        ])
      case .volatile(let track, let text):
        // 받아쓰는 중인 글자. 다음 순간이면 무의미해지므로 재전송하지 않는다.
        self.live.broadcast(event: "volatile",
                            payload: ["track": track.rawValue, "text": text], durable: false)
      case .edited(let id, let text):
        self.live.broadcast(event: "edited", payload: ["id": id, "text": text])
      case .deleted(let ids):
        self.live.broadcast(event: "deleted", payload: ["ids": ids])
      }
    }

    server.handler = { [weak self] req in
      guard let self else { return .response(.notFound) }
      return await self.route(req)
    }

    let port = try bindServer()

    let url = URL(string: "http://127.0.0.1:\(port)/")!
    webURL = url
    log("웹 UI: \(url.absoluteString)")
    log("기본 저장 위치: \(options.baseDir.path)")
    if options.openBrowser { NSWorkspace.shared.open(url) }

    Task { await self.prepareModels() }
  }

  /// 포트를 잡는다. 이미 쓰이고 있으면 그게 우리 인스턴스인지 확인하고,
  /// 맞으면 브라우저만 띄우고 조용히 물러난다. 아니면 다음 포트를 시도한다.
  ///
  /// 이 앱은 Dock 아이콘이 없어서 이미 떠 있는 줄 모르고 다시 실행하기 쉽다.
  /// 예전에는 그럴 때 아무 흔적 없이 죽어서 "가끔 안 켜진다" 로 보였다.
  private func bindServer() throws -> UInt16 {
    var lastError: Error?
    for offset in 0..<5 {
      let port = options.port + UInt16(offset)
      let candidate = (offset == 0) ? server : HTTPServer(port: port)
      if offset > 0 {
        candidate.handler = { [weak self] req in
          guard let self else { return .response(.notFound) }
          return await self.route(req)
        }
      }
      do {
        try candidate.start()
        if offset > 0 {
          logWarn("포트 \(options.port) 가 사용 중이라 \(port) 로 열었습니다.")
          activeServer = candidate
        }
        return port
      } catch {
        lastError = error
        if Self.isOurInstance(port: port) {
          log("이미 ZoomCaption 이 포트 \(port) 에서 실행 중입니다. 브라우저만 엽니다.")
          if let url = URL(string: "http://127.0.0.1:\(port)/") { NSWorkspace.shared.open(url) }
          Logger.shared.log(.info, "중복 실행이라 이번 프로세스는 종료합니다.")
          Thread.sleep(forTimeInterval: 0.3)
          exit(0)
        }
        logWarn("포트 \(port) 를 열지 못했습니다: \(error.localizedDescription)")
      }
    }
    throw lastError ?? TranscriptionError.unavailable
  }

  /// 해당 포트에서 응답하는 게 우리 앱인지 확인한다.
  private static func isOurInstance(port: UInt16) -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/api/state") else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    let semaphore = DispatchSemaphore(value: 0)
    var mine = false
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      mine = json["baseDir"] != nil && json["summaryEngine"] != nil
    }.resume()
    _ = semaphore.wait(timeout: .now() + 3)
    return mine
  }

  /// 시작 시점의 환경을 한 번 기록해 둔다. 문제 신고를 받을 때 이 부분만 보면 된다.
  private func logEnvironment() {
    let info = ProcessInfo.processInfo
    let bundle = Bundle.main.infoDictionary
    log("──────── ZoomCaption 시작 ────────")
    log("버전 \(bundle?["CFBundleShortVersionString"] as? String ?? "?") "
      + "(\(bundle?["CFBundleVersion"] as? String ?? "?"))")
    log("macOS \(info.operatingSystemVersionString)")
    log("메모리 \(info.physicalMemory / 1_073_741_824)GB, CPU \(info.activeProcessorCount)코어")
    log("실행 파일 \(Bundle.main.bundlePath)")
    log("인자 \(info.arguments.dropFirst().joined(separator: " "))")
    log("로그 위치 \(Logger.shared.directory.path) (보관 \(Logger.retentionDays)일)")
    log("mecab-ko \(MecabKo.isAvailable ? MecabKo.versionInfo : "미설치 — 내장 규칙 사용")")
    log("Ollama 바이너리 \(OllamaClient.binaryPath ?? "미설치")")
    let models = OllamaClient.installedModelsOffline()
    log("Ollama 모델 \(models.isEmpty ? "없음" : models.joined(separator: ", "))")
  }

  /// 오디오 입력 진단. 레벨까지 포함해 정규화가 필요한 상태인지 보여 준다.
  private func diagJSON() -> [String: Any] {
    var json: [String: Any] = [:]
    json["framesSeen"] = tap?.framesSeen ?? 0
    json["heardSound"] = tap?.hasHeardSound ?? false
    json["somethingPlaying"] = CoreAudioInfo.isAnythingPlaying()
    json["sourceFormat"] = tap?.sourceFormat.map { "\($0.sampleRate)Hz ch\($0.channelCount)" } ?? "-"
    json["peak"] = Double(tap?.peakLevel ?? 0)
    let db = tap?.peakDBFS ?? -Double.infinity
    json["peakDBFS"] = db.isFinite ? db : -120
    json["rms"] = tap?.rmsLevel ?? 0
    json["levelAdvice"] = Self.levelAdvice(tap)
    let procs: [String] = CoreAudioInfo.processes().map(\.bundleID).filter { !$0.isEmpty }
    json["audioProcesses"] = procs

    // 재전사 경로 진단. 안 될 때 어디가 빈 칸인지 한눈에 보이게 셋을 나눠 둔다.
    let w = Whisper.status
    json["whisperReady"] = w.ready
    json["whisperDetail"] = w.detail
    json["whisperBinary"] = Whisper.binaryPath ?? ""
    
    let cache = DomainCache.stats()
    json["domainCacheCount"] = cache.count
    json["domainCacheKB"] = Int(cache.bytes / 1024)

    let clips = store.sessionDir.map { AudioArchive.clips(in: $0) } ?? []
    json["audioClips"] = clips.count
    json["audioSeconds"] = clips.reduce(Int64(0)) { $0 + $1.bytes } / 32_000
    json["audioMB"] = Double(clips.reduce(Int64(0)) { $0 + $1.bytes }) / 1_048_576
    return json
  }

  /// 입력 레벨을 보고 정규화(게인 보정)가 필요한 상태인지 한 줄로 알려준다.
  private static func levelAdvice(_ tap: SystemAudioTap?) -> String {
    guard let tap, tap.framesSeen > 0 else { return "아직 오디오가 들어오지 않았습니다." }
    guard tap.hasHeardSound else { return "무음만 들어옵니다 — 시스템 오디오 권한을 확인하세요." }
    let db = tap.peakDBFS
    switch db {
    case ..<(-30): return String(format: "입력이 매우 작습니다 (피크 %.1f dBFS). Zoom·시스템 볼륨을 올리면 인식률이 올라갑니다.", db)
    case ..<(-18): return String(format: "입력이 작은 편입니다 (피크 %.1f dBFS).", db)
    case ..<(-1):  return String(format: "입력 레벨 정상 (피크 %.1f dBFS).", db)
    default:       return String(format: "입력이 큽니다 (피크 %.1f dBFS). 클리핑이면 인식이 깨질 수 있습니다.", db)
    }
  }

  // MARK: - 종료

  /// 완전 종료. 기록을 저장하고 자원을 정리한 뒤 프로세스를 끝낸다.
  ///
  /// 단계마다 로그를 남긴다. 예전에는 이 경로에 로그가 하나도 없어서
  /// 종료가 안 될 때 어디서 막혔는지 알아낼 방법이 없었다.
  private func shutdown() async {
    // 브라우저가 "종료했습니다" 응답을 받을 틈을 준다.
    try? await Task.sleep(for: .milliseconds(250))

    log("종료 1/3 — 녹음을 멈추고 저장합니다.")
    _ = await stop()

    log("종료 2/3 — Ollama 서버를 정리합니다.")
    OllamaClient.shutdownSpawnedServer()

    log("종료 3/3 — 웹 서버를 닫습니다.")
    live.stop()

    log("──────── ZoomCaption 종료 ────────")
    Logger.shared.flush()
    exit(0)
  }

  /// 정해진 시간 안에 정리가 끝나지 않으면 강제로 끝낸다.
  ///
  /// 협력 스레드 풀이 아니라 진짜 스레드에 태워야 한다.
  /// 정리 쪽이 스레드를 물고 늘어져도 이 감시자는 반드시 깨어나야 하기 때문이다.
  private static func armQuitWatchdog(seconds: Double) {
    let watchdog = Thread {
      Thread.sleep(forTimeInterval: seconds)
      Logger.shared.log(.warn, "정리가 \(Int(seconds))초 안에 끝나지 않아 강제로 종료합니다.")
      Logger.shared.flush()
      exit(0)
    }
    watchdog.name = "zoomcaption.quit-watchdog"
    watchdog.start()
  }

  /// Dock 아이콘도 창도 없는 앱이라, 사용자가 다시 실행해도 화면에 아무 변화가 없다.
  /// macOS 는 이럴 때 새 프로세스를 띄우지 않고 기존 인스턴스를 재활성화만 한다.
  /// 그 신호를 받아 웹 UI 를 다시 열어 준다.
  func handleReopen() {
    guard let webURL, let port = webURL.port.map(UInt16.init) else { return }
    // **내 서버가 아직 살아 있는지 먼저 확인한다.**
    //
    // 이게 없으면 서버가 죽은 채 프로세스만 남았을 때 빈 페이지가 열린다.
    // 그 상태에서는 앱을 몇 번을 다시 눌러도 macOS 가 이 껍데기를 깨우기만 해서
    // 영영 안 켜진다 — 실제로 사용자가 세 번 눌러 세 번 다 빈 페이지를 봤다.
    guard Self.isOurInstance(port: port) else {
      logWarn("웹 서버가 이미 내려가 있습니다 — 이 프로세스를 정리합니다. 다시 실행해 주세요.")
      Logger.shared.flush()
      exit(0)
    }
    log("앱을 다시 실행했습니다 — 웹 UI 를 다시 엽니다: \(webURL.absoluteString)")
    NSWorkspace.shared.open(webURL)
  }

  private func prepareModels() async {
    do {
      let locale = try await TrackTranscriber.prepareAssets(locale: Locale(identifier: options.localeID)) { frac in
        self.live.broadcast(event: "status", payload: [
          "message": "한국어 인식 모델 내려받는 중… \(Int(frac * 100))%", "level": "info",
        ])
      }
      let fmt = try await TrackTranscriber.analyzerFormat(locale: locale)
      stateLock.withLock { resolvedLocale = locale; analyzerFormat = fmt }
      log("모델 준비 완료: \(locale.identifier), \(fmt.sampleRate)Hz")
      live.broadcast(event: "status", payload: ["message": "", "level": "info"])
    } catch {
      logError("음성 인식 모델 준비 실패: \(error.localizedDescription)")
      live.broadcast(event: "status", payload: [
        "message": "음성 인식 준비 실패: \(error.localizedDescription)", "level": "warn",
      ])
    }
  }

  // MARK: - 라우팅

  private func route(_ req: HTTPRequest) async -> Route {
    switch (req.method, req.path) {
    case ("GET", "/"):
      return .response(.html(WebUI.page))

    case ("GET", "/events"):
      return .eventStream

    // 주기 대조용 최소 정보. 90분 수업의 /api/state 는 수백 KB 라 이걸 대신 쓴다.
    case ("GET", "/api/sync"):
      return .response(.json([
        "seq": live.currentSeq,
        "boot": live.bootID,
        "running": stateLock.withLock { running },
        "whisper": store.whisperSegments.count,
        "live": store.allSegments.count,
        "session": store.sessionDir?.path ?? "",
      ]))

    case ("GET", "/api/state"):
      return .response(.json(await stateJSON()))

    case ("GET", "/api/logs"):
      let limit = Int(req.query["limit"] ?? "300") ?? 300
      return .response(.json([
        "lines": Logger.shared.recent(limit: max(20, min(1000, limit))),
        "directory": Logger.shared.directory.path,
        "retentionDays": Logger.retentionDays,
        "files": Logger.shared.files().map { ["name": $0.name, "size": $0.size] },
      ]))

    case ("POST", "/api/logs/reveal"):
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Logger.shared.directory.path)
      return .response(.json(["ok": true]))

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
        stateLock.withLock { running = true; adminFeedPending = true }
        do { try await start(title: r.title ?? "관리자 시험", terms: [],
                             folder: nil, baseDir: nil, keepAudio: true) }
        catch {
          stateLock.withLock { running = false; adminFeedPending = false }
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

    // ── 본문에서 바로 고치기 ──
    //
    // 갈린 자리에 밑줄을 긋고, 눌러서 실시간 쪽 표기를 보고, 골라서 고친다.
    // 사용자가 어차피 하는 일(복습하며 읽기) 위에 얹히기 때문에 따로 드는 시간이 없다.
    case ("POST", "/api/fix"):
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

    case ("GET", "/api/diag"):
      return .response(.json(diagJSON()))

    // ── 세션 ──
    case ("GET", "/api/sessions"):
      return .response(.json(["sessions": SessionStore.list(base: options.baseDir)]))

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
      stateLock.withLock { pendingDomainPDF = nil }
      return .response(.json(["ok": true, "state": await stateJSON()]))

    case ("POST", "/api/pickFolder"):
      // osascript 를 띄우고 사용자가 고를 때까지 기다린다. 메인 스레드를 막지 않도록 분리 실행.
      let start = store.sessionDir?.deletingLastPathComponent() ?? options.baseDir
      let picked = await Task.detached { SessionStore.pickFolder(startingAt: start) }.value
      return .response(.json(["ok": picked != nil, "path": picked ?? ""]))

    case ("POST", "/api/save"):
      do {
        if store.sessionDir == nil {
          let dir = try SessionStore.createDir(base: options.baseDir, name: nil, title: store.title)
          store.sessionDir = dir
          adoptPendingDomainPDF(into: dir)
        }
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
        if running { return false }
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
        return .response(.json(["ok": true, "state": await stateJSON()]))
      } catch {
        // 잡아둔 자리를 반드시 놓아준다. 안 그러면 다시는 시작할 수 없다.
        stateLock.withLock { running = false }
        live.broadcast(event: "status", payload: ["running": false])
        logError("녹음 시작 실패: \(error)")
        return .response(.json(["ok": false, "error": error.localizedDescription]))
      }

    case ("POST", "/api/stop"):
      let saved = await stop()
      return .response(.json(["ok": true, "saved": saved ?? "", "state": await stateJSON()]))

    // ── 편집 ──
    case ("POST", "/api/segment/update"):
      guard let r = req.json(EditRequest.self), let id = r.id else {
        return .response(.json(["ok": false, "error": "잘못된 요청"]))
      }
      let ok = r.list == "whisper"
        ? store.updateWhisperSegment(id: id, text: r.text ?? "")
        : store.updateSegment(id: id, text: r.text ?? "")
      autosave()
      return .response(.json(["ok": ok]))

    case ("POST", "/api/segment/delete"):
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
      guard !store.segments(from: from).isEmpty else {
        return .response(.json(["ok": false,
                                "error": from == nil ? "요약할 기록이 없습니다."
                                                     : "지정한 시각 이후에 기록이 없습니다."]))
      }
      Task { await self.runSummary(from: from) }
      return .response(.json(["ok": true]))

    case ("POST", "/api/summary/save"):
      guard let summary = store.summary, !summary.isEmpty else {
        return .response(.json(["ok": false, "error": "저장할 요약이 없습니다."]))
      }
      let r = req.json(SaveSummaryRequest.self)
      let dir = (r?.dir?.isEmpty == false) ? URL(fileURLWithPath: r!.dir!)
                                           : (store.sessionDir ?? options.baseDir)
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
      return .response(.notFound)
    }
  }

  // MARK: - 교안 PDF

  private func handleDomainUpload(_ req: HTTPRequest) async -> HTTPResponse {
    let name = req.query["name"].map { SessionStore.sanitize($0) } ?? "교안.pdf"
    guard !req.body.isEmpty else {
      return .json(["ok": false, "error": "파일이 비어 있습니다."])
    }

    // 세션 폴더가 있으면 그 안에, 없으면 임시 폴더에 두었다가 나중에 옮긴다.
    let target: URL
    if let dir = store.sessionDir {
      target = dir.appendingPathComponent(name)
    } else {
      let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("zoomcaption-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      target = tmp.appendingPathComponent(name)
    }

    do {
      try req.body.write(to: target, options: .atomic)

      if store.sessionDir == nil {
        stateLock.withLock { pendingDomainPDF = (name, target) }
      }

      // 같은 교안을 다시 올리는 일이 잦다(이어 적기, 새 세션, 앱 재시작).
      // 파일 내용 해시로 붙잡아 두면 mecab 9초 + 모델 정제 18초를 통째로 건너뛴다.
      let t0 = Date()
      let cacheKey = DomainCache.key(for: req.body)
      var entry = DomainCache.load(key: cacheKey)
      let fromCache = entry != nil

      if let hit = entry {
        log("교안 캐시 적중: \(name) — \(hit.pages)쪽, 용어 \(hit.terms.count)개 "
          + "[\(hit.refinedBy)], \(Self.ago(hit.cachedAt)) 분석한 결과")
      } else {
        let result = try DomainKnowledge.analyze(pdf: target)

        // 규칙으로 거른 뒤, 로컬 모델이 있으면 "강의에서 말할 용어" 만 남긴다.
        // 코드 조각은 언어별 예약어 목록 없이 이 단계에서 걸러진다.
        var terms = result.terms
        var refinedBy = "규칙"
        if !terms.isEmpty, await OllamaClient.ensureServer(),
           let installed = await OllamaClient.installedModels(),
           let model = OllamaClient.pickModel(from: installed),
           let filtered = await OllamaClient.filterLectureTerms(terms, model: model) {
          log("교안 용어 LLM 정제: \(terms.count)개 → \(filtered.count)개 (\(model))")
          terms = filtered
          refinedBy = "규칙 + \(model)"
        }

        let made = DomainCache.Entry(
          pages: result.pages, characters: result.characters, terms: terms,
          looksScanned: result.looksScanned, analyzer: result.analyzer,
          droppedBoilerplate: result.droppedBoilerplate, refinedBy: refinedBy,
          sourceName: name, cachedAt: Date(), version: 0)
        // 스캔본은 담아둘 게 없으니 캐시하지 않는다. OCR 을 돌린 뒤 다시 올릴 수 있어야 한다.
        if !result.looksScanned { DomainCache.save(key: cacheKey, made) }
        entry = made
      }

      guard let entry else { return .json(["ok": false, "error": "교안을 분석하지 못했습니다."]) }

      store.domainTerms = entry.terms
      store.domainSource = name
      autosave()

      let ms = Int(Date().timeIntervalSince(t0) * 1000)
      log("교안 반영: \(name) — \(entry.pages)쪽, \(entry.characters)자, 용어 \(entry.terms.count)개 "
        + "[\(entry.refinedBy)] \(fromCache ? "캐시" : "새로 분석") \(ms)ms")
      return .json([
        "ok": true,
        "name": name,
        "pages": entry.pages,
        "characters": entry.characters,
        "terms": entry.terms,
        "refinedBy": entry.refinedBy,
        "scanned": entry.looksScanned,
        "cached": fromCache,
        "elapsedMs": ms,
      ])
    } catch {
      return .json(["ok": false, "error": error.localizedDescription])
    }
  }

  /// 정답지 상태와, 그 구간에 대한 두 전사기의 성적.
  ///
  /// 한국어는 띄어쓰기가 불안정해 단어 오류율(WER)보다 **글자 오류율(CER)** 이 맞다.
  /// 이 세션에 모인 표본과 성적.
  private func goldJSON() -> [String: Any] {
    guard let dir = store.sessionDir else {
      return ["ok": true, "samples": [], "judged": [], "score": GoldScore.summary([])]
    }
    let set = GoldSet.load(from: dir)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let rows: [[String: Any]] = set.samples
      .sorted { $0.start < $1.start }
      .map { s in
        ["key": s.key, "start": s.start, "end": s.end, "kind": s.kind,
         "live": s.live, "whisper": s.whisper, "truth": s.truth, "verdict": s.verdict]
      }
    return [
      "ok": true,
      "samples": rows,
      "judged": Array(set.judged),          // 화면에서 이미 본 지점을 건너뛰기 위해
      "score": GoldScore.summary(set.samples),
      "hasAudio": !AudioArchive.clips(in: dir).isEmpty,
    ]
  }

  /// 이 수업에 딸린, 실제로 디스크에 남아 있는 요약 파일들.
  ///
  /// 수업이 1교시·2교시로 나뉘면 요약도 여러 번 나온다. 세션 안의 `summary` 는
  /// 마지막 것 하나뿐이라, 앞서 저장한 요약은 파일로만 남는다. 그걸 다시 찾아준다.
  private func summariesJSON() -> [[String: Any]] {
    let fm = FileManager.default
    var out: [[String: Any]] = []
    var seen = Set<String>()
    // 기록해 둔 경로 + 세션 폴더 안의 *_요약.md 를 합친다(밖에 저장한 것도 잡히도록)
    var candidates = store.summaryFiles
    if let dir = store.sessionDir, let names = try? fm.contentsOfDirectory(atPath: dir.path) {
      candidates += names.filter { $0.hasSuffix(".md") && $0.contains("요약") }
        .map { dir.appendingPathComponent($0).path }
    }
    for path in candidates {
      guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
      seen.insert(path)
      let attrs = try? fm.attributesOfItem(atPath: path)
      out.append([
        "path": path,
        "name": (path as NSString).lastPathComponent,
        "size": (attrs?[.size] as? Int) ?? 0,
        "savedAt": ((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970,
      ])
    }
    return out.sorted { ($0["savedAt"] as! Double) > ($1["savedAt"] as! Double) }
  }

  /// "3일 전" 같은 사람이 읽는 표현
  private static func ago(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    switch seconds {
    case ..<90: return "방금"
    case ..<3600: return "\(Int(seconds / 60))분 전"
    case ..<86400: return "\(Int(seconds / 3600))시간 전"
    default: return "\(Int(seconds / 86400))일 전"
    }
  }

  private func adoptPendingDomainPDF(into dir: URL) {
    guard let pending = stateLock.withLock({ pendingDomainPDF }) else { return }
    let dest = dir.appendingPathComponent(pending.name)
    try? FileManager.default.removeItem(at: dest)
    try? FileManager.default.copyItem(at: pending.url, to: dest)
    try? FileManager.default.removeItem(at: pending.url.deletingLastPathComponent())
    stateLock.withLock { pendingDomainPDF = nil }
  }

  // MARK: - 상태

  private func stateJSON() async -> [String: Any] {
    let segs = store.allSegments.map {
      ["id": $0.id, "start": $0.start, "end": $0.end,
       "text": $0.text, "edited": $0.edited] as [String: Any]
    }
    let isRunning = stateLock.withLock { running }
    let engine = await Summarizer.currentEngine()
    let whisper = store.whisperSegments.map {
      ["id": $0.id, "start": $0.start, "end": $0.end,
       "text": $0.text, "edited": $0.edited] as [String: Any]
    }
    var json: [String: Any] = [
      // 화면이 "내가 여기까지 봤다" 를 대조할 기준점. 이벤트를 놓쳤는지 이걸로 안다.
      "seq": live.currentSeq,
      "boot": live.bootID,
      "running": isRunning,
      "title": store.title,
      "segments": segs,
      "whisperSegments": whisper,
      "baseDir": options.baseDir.path,
      "sessionDir": store.sessionDir?.path ?? "",
      "sessionName": store.sessionDir?.lastPathComponent ?? "",
      "elapsed": store.elapsed,
      // 브라우저를 새로 열어도 타이머가 0부터 다시 세지 않도록 실제 시작 시각을 넘긴다.
      "startedAt": store.startedAt?.timeIntervalSince1970 ?? 0,
      "duration": store.duration,
      "timeBase": store.timeBase,
      "continuing": store.timeBase > 0,
      "domainSource": store.domainSource ?? "",
      "domainTerms": store.domainTerms,
      "lastSummarizedAt": store.lastSummarizedAt ?? 0,
      "whisperReady": Whisper.isReady,
      "whisperDetail": Whisper.status.detail,
      "whisperLiveNote": stateLock.withLock { whisperLiveNote } ?? "",
      "hasCorrections": store.hasCorrections,
      "whisperLines": store.whisperSegments.count,
      "audioClips": store.sessionDir.map { AudioArchive.clips(in: $0).count } ?? 0,
      "audioSeconds": Int((store.sessionDir.map { AudioArchive.clips(in: $0) } ?? [])
        .reduce(Int64(0)) { $0 + $1.bytes } / 32_000),
    ]
    if let sum = store.summary { json["summary"] = sum }
    json["summaryEngine"] = engine.label
    if let note = engine.note { json["summarizerNote"] = note }
    return json
  }

  private func fileStem() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HHmm"
    return "\(df.string(from: store.createdAt))_\(SessionStore.sanitize(store.title))"
  }

  private func autosave() {
    guard store.sessionDir != nil else { return }
    do { try SessionStore.save(store) } catch { logWarn("자동 저장 실패: \(error.localizedDescription)") }
  }

  // MARK: - 세션 제어

  private func start(title: String?, terms: [String],
                     folder: String?, baseDir: String?, keepAudio: Bool) async throws {
    // 자리는 라우트에서 이미 잡았다(running = true). 여기서 다시 확인하지 않는다.

    var locale = stateLock.withLock { resolvedLocale }
    var format = stateLock.withLock { analyzerFormat }
    if locale == nil || format == nil {
      let l = try await TrackTranscriber.prepareAssets(locale: Locale(identifier: options.localeID))
      let f = try await TrackTranscriber.analyzerFormat(locale: l)
      stateLock.withLock { resolvedLocale = l; analyzerFormat = f }
      locale = l; format = f
    }
    guard let locale, let format else { throw TranscriptionError.unavailable }

    // 제목을 안 보냈으면 기존 세션 제목을 유지한다 (이어 적기에서 덮어쓰지 않도록).
    if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { store.title = title }
    stateLock.withLock { userTerms = terms }

    // 이어 적기가 아니면 이번 수업용 폴더를 만든다.
    if store.sessionDir == nil {
      let parent = (baseDir?.isEmpty == false) ? URL(fileURLWithPath: baseDir!) : options.baseDir
      let dir = try SessionStore.createDir(base: parent, name: folder, title: store.title)
      store.sessionDir = dir
      adoptPendingDomainPDF(into: dir)
      log("세션 폴더: \(dir.path)")
    }
    store.beginRecording()

    // 사용자가 적은 용어 + 교안에서 뽑은 용어
    let allTerms = Array((terms + store.domainTerms).reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }.prefix(DomainKnowledge.maxContextualTerms))

    let lecture = TrackTranscriber()
    try await lecture.start(locale: locale, audioFormat: format, contextualStrings: allTerms,
                            onFinal: { [store] s, e, t, w in
                              store.appendFinal(track: .lecture, start: s, end: e, text: t,
                                                words: w) },
                            onVolatile: { [store] t in store.setVolatile(track: .lecture, text: t) })
    lectureTranscriber = lecture

    // 소리 보관은 부가 기능이다. 만들다 실패해도 녹취는 그대로 간다.
    var clip: AudioArchive?
    stateLock.withLock {
      whisperLiveNote = keepAudio ? (Whisper.isReady ? nil : Whisper.status.detail)
                                  : "설정에서 ‘소리도 함께 저장’ 이 꺼져 있어 Whisper 를 돌릴 수 없습니다."
    }
    if keepAudio, let dir = store.sessionDir {
      do {
        clip = try AudioArchive(dir: dir, startOffset: store.timeBase)
        log("소리 저장: \(clip!.url.lastPathComponent) (16kHz mono, 시간당 약 110MB)")

        // 소리를 남기는 김에, 수업이 도는 동안 Whisper 도 뒤에서 돌린다.
        if Whisper.isReady {
          let worker = WhisperLive(
            prompt: allTerms.prefix(60).joined(separator: ", "),
            onLines: { [weak self] lines in
              guard let self else { return }
              for seg in self.store.appendWhisper(lines) {
                // 그 시각에 실제로 소리가 있었는지 대조한다. 지우지 않고 알리기만 한다 —
                // 아직 근거가 환각 6건뿐이라, 오탐이 없는지 확인하는 단계다.
                // Whisper 가 VAD 로 무음을 안 읽으므로 평소엔 걸릴 게 없다.
                // 그래도 **로그에는 남긴다** — VAD 가 조용히 멈춰도 알 수 있어야 한다.
                if let dir = self.store.sessionDir,
                   let db = AudioSlice.peakDBFS(dir: dir, from: seg.start, to: seg.end),
                   db < AudioSlice.quietCeiling {
                  logWarn("무음 위에 적힘 — \(TranscriptStore.clock(seg.start)) "
                        + "피크 \(String(format: "%.1f", db))dBFS 「\(seg.text.prefix(40))」 "
                        + "(VAD 가 안 도는지 확인하세요)")
                }
                self.live.broadcast(event: "whisperSegment", payload: [
                  "id": seg.id, "start": seg.start, "end": seg.end, "text": seg.text])
              }
              self.autosave()
            },
            onProgress: { [weak self] done, total in
              self?.live.broadcast(event: "whisperLive",
                             payload: ["done": done, "total": total], durable: false)
            })
          whisperLive = worker
          clip!.onChunk = { [weak worker] url, start in worker?.enqueue(url: url, start: start) }
          log("Whisper 실시간 재전사 켬 — \(Int(AudioArchive.chunkSeconds))초 조각, "
            + "겹침 \(Int(AudioArchive.overlapSeconds))초, 모델 \(Whisper.modelPath?.lastPathComponent ?? "?")")
        } else {
          log("Whisper 를 쓸 수 없어 실시간 재전사는 건너뜁니다 — \(Whisper.status.detail)")
        }
      } catch {
        // 여기서 넘어지면 Whisper 로 넘길 조각도 안 만들어진다.
        // 위 칸이 조용히 비어 있는 게 아니라 이유가 보여야 한다.
        logWarn("소리 저장을 시작하지 못했습니다: \(error.localizedDescription)")
        clip = nil
        stateLock.withLock {
          whisperLiveNote = "소리를 저장하지 못해 Whisper 를 돌릴 수 없습니다 — \(error.localizedDescription)"
        }
        live.broadcast(event: "status", payload: [
          "message": "소리 저장 실패로 Whisper 자막이 만들어지지 않습니다: \(error.localizedDescription)",
          "level": "warn"])
      }
    }
    live.broadcast(event: "whisperLive", payload: [
      "done": 0, "total": 0, "note": stateLock.withLock { whisperLiveNote } ?? ""])
    archive = clip

    let sink: @Sendable (AVAudioPCMBuffer) -> Void = { [weak lecture] buf in
      lecture?.feed(buf)
      clip?.write(buf)
    }
    audioSink = sink

    // 관리자 모드에서는 파일 되먹임으로 소리를 넣을 수 있어야 하므로 탭 없이도 시작한다.
    if stateLock.withLock({ adminFeedPending }) {
      stateLock.withLock { adminFeedPending = false }
      live.broadcast(event: "status", payload: ["running": true, "message": ""])
      log("녹음 시작 (관리자 되먹임) — \(store.title)")
      return
    }

    let audioTap = SystemAudioTap(onBuffer: sink)
    do {
      // 관리자 모드면 Zoom 만이 아니라 시스템 전체 소리를 듣는다.
      // 표본 오디오를 아무 재생기로 틀어도 잡히므로 Zoom 없이 시험할 수 있다.
      try audioTap.start(zoomOnly: !options.admin)
    } catch {
      await lecture.finish()
      lectureTranscriber = nil
      archive?.finish(); archive = nil
      throw error
    }
    tap = audioTap

    // running 은 라우트에서 이미 세웠다. 여기서는 화면에만 알린다.
    live.broadcast(event: "status", payload: ["running": true, "message": ""])
    startSilenceWatchdog()

    log("녹음 시작 — \(store.title)\(store.timeBase > 0 ? " (이어 적기, \(TranscriptStore.clock(store.timeBase))부터)" : "")")
  }

  /// 소리가 하나도 안 들어오는 상태를 알린다.
  ///
  /// 원인이 둘인데 대처법이 정반대라 반드시 구분해서 말해야 한다.
  /// ① 권한 없음 — macOS 는 오류 대신 무음을 흘려보낸다. 설정에서 권한을 켜야 한다.
  /// ② Zoom 이 조용함 — 회의에 안 들어갔거나 발표자가 말을 안 하는 것. 기다리면 된다.
  ///    이때 다른 앱(브라우저 강의 영상 등)이 소리를 내고 있으면 그건 잡히지 않는다.
  private func startSilenceWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 12, repeating: 20)
    timer.setEventHandler { [weak self] in
      guard let self, let tap = self.tap else { return }
      guard tap.framesSeen > 0, !tap.hasHeardSound else { return }

      // "앱이 떠 있다" 가 아니라 "지금 소리를 내고 있다" 로 판정해야 한다.
      // Zoom 은 회의에 안 들어가 있어도 오디오 프로세스를 들고 있어서, 앱 존재로 재면 늘 참이 된다.
      let playing = CoreAudioInfo.playingBundleIDs()
      let zoomPlaying = playing.contains { SystemAudioTap.zoomBundleIDs.contains($0) }
      let others = playing.filter { !SystemAudioTap.zoomBundleIDs.contains($0) }
      guard !playing.isEmpty else { return }   // 온 시스템이 조용하면 알릴 게 없다

      self.live.broadcast(event: "status", payload: [
        "silent": true,
        "zoomPlaying": zoomPlaying,
        "others": Array(others.prefix(4)),
      ])
    }
    timer.resume()
    silenceWatchdog = timer
  }

  @discardableResult
  private func stop() async -> String? {
    let wasRunning = stateLock.withLock { () -> Bool in
      let was = running
      running = false
      return was
    }
    // running 이 어긋나 있어도 캡처가 살아 있거나 기록이 남아 있으면 끝까지 정리하고 저장한다.
    // 여기서 그냥 빠져나가면 사용자가 정지를 눌러도 녹취가 통째로 사라진다.
    let hasWork = tap != nil || lectureTranscriber != nil || !store.isEmpty
    guard wasRunning || hasWork else { return nil }
    if !wasRunning { logWarn("running 플래그가 꺼져 있었지만 남은 기록을 정리해 저장합니다.") }

    silenceWatchdog?.cancel(); silenceWatchdog = nil
    tap?.stop(); tap = nil

    // 탭을 멈춘 뒤에 닫아야 마지막 버퍼까지 들어간다.
    // finish() 안에서 자투리가 마지막 조각으로 나가므로 Whisper 를 기다리는 건 그다음이다.
    if let done = archive?.finish() {
      log(String(format: "소리 저장 완료: %@ — %.0f초, %.1fMB",
                 done.url.lastPathComponent, done.seconds, Double(done.bytes) / 1_048_576))
    }
    archive = nil

    if let worker = whisperLive {
      let (done, total) = worker.progress
      if done < total {
        log("Whisper 남은 조각 \(total - done)개를 마저 처리합니다.")
        live.broadcast(event: "status", payload: [
          "message": "Whisper 가 마지막 구간을 정리하는 중입니다…", "level": "info"])
      }
      await worker.finish()
      log("Whisper 실시간 재전사 종료 — 조각 \(worker.progress.done)개, \(store.whisperSegments.count)줄")
      whisperLive = nil
    }

    await lectureTranscriber?.finish(); lectureTranscriber = nil

    store.endRecording()
    live.broadcast(event: "status", payload: ["running": false])
    // 남아 있던 미확정 자막은 화면에서 지운다.
    live.broadcast(event: "volatile",
                   payload: ["track": Track.lecture.rawValue, "text": ""], durable: false)

    guard !store.isEmpty else { log("기록이 비어 있어 저장하지 않음"); return nil }
    do {
      // 세션 폴더가 없으면(예: 시작 도중 실패) 여기서 만들어서라도 남긴다.
      if store.sessionDir == nil {
        let dir = try SessionStore.createDir(base: options.baseDir, name: nil, title: store.title)
        store.sessionDir = dir
        adoptPendingDomainPDF(into: dir)
        log("세션 폴더가 없어 새로 만들었습니다: \(dir.lastPathComponent)")
      }
      guard let dir = try SessionStore.save(store) else {
        logError("저장 대상 폴더를 정하지 못했습니다")
        return nil
      }
      log("저장 완료: \(dir.path)")
      live.broadcast(event: "status", payload: [
        "message": "저장했습니다 → \(dir.lastPathComponent)", "level": "info",
      ])
      return dir.path
    } catch {
      logError("저장 실패: \(error)")
      live.broadcast(event: "status", payload: [
        "message": "저장 실패: \(error.localizedDescription)", "level": "warn",
      ])
      return nil
    }
  }

  // MARK: - 문맥 교정

  /// Whisper 기록을 원안으로 두고, 정렬기가 찾아낸 갈린 지점만 모델에 묻는다.
  /// 결과는 곧바로 반영하지 않고 제안 목록으로 내보낸다 — 사람이 보고 고르게 한다.
  // MARK: - 요약

  private func runSummary(from: Double?) async {
    let scoped = store.segments(from: from)
    let text = store.plainText(from: from)
    log("요약 시작 — 범위 \(from.map { TranscriptStore.clock($0) + " 이후" } ?? "전체"), "
      + "\(scoped.count)줄 / \(text.count)자, 교안 용어 \(store.domainTerms.count)개")
    let glossary = DomainKnowledge.glossary(store.domainTerms)
    let result = await Summarizer.summarize(transcript: text, title: store.title, glossary: glossary) { done, total in
      self.live.broadcast(event: "summaryProgress",
                          payload: ["done": done, "total": total], durable: false)
    }
    store.summary = result
    let lastAt = scoped.map(\.end).max()
    store.lastSummarizedAt = lastAt
    live.broadcast(event: "summaryDone", payload: [
      "markdown": result,
      "lastSummarizedAt": lastAt ?? 0,
      "from": from ?? 0,
    ])
    autosave()
    log("요약 완료 — 마지막 지점 \(lastAt.map(TranscriptStore.clock) ?? "-")")
  }
}

// MARK: - 자가진단

/// 오디오 권한과 무관하게 음성 인식 경로만 검증한다. `--selftest <오디오파일>`
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

// MARK: - 진입점

let rawArgs = Array(CommandLine.arguments.dropFirst())

if let idx = rawArgs.firstIndex(of: "--pdftest"), idx + 1 < rawArgs.count {
  let path = rawArgs[idx + 1]
  let useLLM = rawArgs.contains("--llm")
  Task { await runPDFTest(path: path, useLLM: useLLM) }
  RunLoop.main.run()
}

if let idx = rawArgs.firstIndex(of: "--sumtest"), idx + 1 < rawArgs.count {
  var pdf: String?
  if let p = rawArgs.firstIndex(of: "--pdf"), p + 1 < rawArgs.count { pdf = rawArgs[p + 1] }
  let path = rawArgs[idx + 1]
  Task { await runSumTest(path: path, pdf: pdf) }
  RunLoop.main.run()
}

if let idx = rawArgs.firstIndex(of: "--selftest"), idx + 1 < rawArgs.count {
  let opts = Options.parse(rawArgs)
  let path = rawArgs[idx + 1]
  var terms: [String] = []
  if let t = rawArgs.firstIndex(of: "--terms"), t + 1 < rawArgs.count {
    terms = rawArgs[t + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  }
  Task { await runSelfTest(path: path, localeID: opts.localeID, terms: terms) }
  RunLoop.main.run()
}

let options = Options.parse(rawArgs)
let app = ZoomCaptionApp(options: options)

do {
  try app.boot()
} catch {
  logError("시작 실패: \(error.localizedDescription)")
  logError("포트 \(options.port) 부터 5개를 시도했지만 모두 열지 못했습니다. --port 로 바꿔 실행하세요.")
  exit(1)
}

/// 이미 실행 중인 상태에서 앱을 다시 열었을 때를 받아 준다.
final class AppDelegate: NSObject, NSApplicationDelegate {
  var onReopen: (() -> Void)?
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    onReopen?()
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    log("──────── ZoomCaption 종료 ────────")
  }
}

let delegate = AppDelegate()
delegate.onReopen = { [weak app] in app?.handleReopen() }

let nsApp = NSApplication.shared
nsApp.delegate = delegate
nsApp.setActivationPolicy(.accessory)
nsApp.run()

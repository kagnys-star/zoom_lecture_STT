import Foundation
import AVFoundation
import AppKit

// MARK: - 앱

/// 앱 하나의 전부 — 웹 서버를 띄우고, 녹음을 켜고 끄고, 기록을 들고 있는다.
///
/// 라우트 처리는 `Server/Routes/` 아래로 나눠 두었다(같은 타입의 extension 이다).
/// 그래서 이 파일에는 **수명주기와 상태**만 남는다.
final class ZoomCaptionApp: @unchecked Sendable {
  /// 탭이 시작된 뒤 발생할 수 있는 경로 장애만 나타낸다. Zoom이 시작 전에 없는
  /// 경우는 대기 상태로 만들지 않고 `start()` 오류로 반환하므로 여기에 포함하지 않는다.
  private enum AudioCaptureIssue: Equatable {
    case callbackStalled
    case targetProcessLost
    case outputRouteChanged
  }

  // 아래 멤버 중 `private` 이 없는 것들은 `Server/Routes/` 의 extension 이 쓴다.
  // Swift 의 `private` 는 **같은 파일 안**까지만이라, extension 을 파일로 나누면 안 보인다.
  // 모듈 밖으로 나가지 않으므로 internal(기본값) 로 두었다.
  // 여러 파일로 나눈 라우트 extension이 관리자 여부와 저장 위치를 판단한다.
  // Swift의 private은 같은 파일 밖 extension에서 보이지 않으므로 모듈 내부 접근으로 둔다.
  let options: Options
  let store = TranscriptStore()
  private let server: HTTPServer
  /// 기본 포트가 막혀 다른 포트로 열었을 때 실제로 쓰는 서버
  private var activeServer: HTTPServer?
  /// 브로드캐스트·종료는 반드시 실제로 열린 서버로 가야 한다
  var live: HTTPServer { activeServer ?? server }
  /// 실제로 열린 웹 UI 주소. 앱을 다시 실행했을 때 이 주소를 다시 연다.
  private(set) var webURL: URL?

  private var tap: SystemAudioTap?
  /// 시스템 탭과 관리자 파일 되먹임이 함께 갱신하는 마지막 유효 소리 시계.
  /// 장치 객체(`tap`)와 분리돼 있어 관리자 시험에서도 180초 무음 경로가 동일하게 돈다.
  private var audioActivityClock: AudioActivityClock?
  /// 실제 Core Audio 탭에서 마지막 버퍼가 도착한 시각을 추적한다. 샘플이 0이어도
  /// 갱신되므로 정상 침묵과 콜백 중단을 `AudioActivityClock`에 섞지 않고 구분한다.
  /// 관리자 파일 되먹임은 실제 탭을 우회하므로 이 heartbeat를 사용하지 않는다.
  private var audioCaptureHeartbeat: AudioCaptureHeartbeat?
  /// 관리자 되먹임. 저장된 WAV 를 실제 탭과 **같은 닫힘**에 밀어 넣어 전체 경로를 시험한다.
  let adminFeed = AdminFeed()
  /// 운영 녹음과 분리된 관리자 A/B 측정기. 전사·저장을 하지 않고 Zoom 후보별
  /// 콜백과 레벨만 재므로 최종 캡처 경로를 확정하기 전에 출처를 비교할 수 있다.
  let administratorAudioProbe = AdministratorAudioCaptureProbeController()
  /// 지금 녹음이 쓰는 오디오 받개. 되먹임이 여기로 들어간다.
  var audioSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
  /// 이번 시작은 탭 없이(되먹임으로) 간다는 표시
  var adminFeedPending = false

  /// 무음 의심 줄이 "진짜 말이었다" 고 볼 최소 근거 — 실시간 기록과 겹치는 글자 수.
  ///
  /// 실측(환각 5건 대 진짜 2건)에서 이 값으로 깨끗하게 갈렸다:
  /// 환각은 0·1·2·2·0자, 진짜는 7자·51자. 비율로 재면 안 된다 —
  /// 「감사합니다」는 5자뿐이라 2자만 우연히 겹쳐도 40%가 된다.
  static let liveSupportChars = 5

  private var lectureTranscriber: TrackTranscriber?
  /// 이번 녹음 구간의 소리를 담는 WAV. 나중에 재전사·확인에 쓴다.
  private var archive: AudioArchive?
  /// 사용자가 정한 것은 오디오 처리 여부가 아니라 처리 완료 뒤 원본 보관 여부다.
  /// start/stop 전체가 같은 상태 전이 가드로 직렬화되므로 한 녹음 구간 동안 값이 바뀌지
  /// 않으며, 체크박스를 다음 녹음용으로 바꿔도 이미 진행 중인 파일 정책은 흔들리지 않는다.
  private var retainOriginalAudioAfterTranscription = true
  /// 수업이 도는 동안 뒤에서 Whisper 를 돌리는 워커
  private var whisperLive: WhisperLive?
  /// Whisper 가 청크 단위로 끊어 주는 줄을 마침표 기준 문장으로 다시 짜 맞춘다.
  private var sentenceBuffer: SentenceReconstructor?
  /// 실시간 재전사가 안 돌고 있다면 그 이유. 위 칸이 왜 비어 있는지 화면에 그대로 띄운다.
  private var whisperLiveNote: String?
  /// 콘텐츠 무음과 180초 강의 경계만 감시한다. 캡처 경로 생존 여부는 아래의 별도
  /// 타이머가 맡아, 정상적인 강의 침묵이 빨간 장애 경고로 승격되지 않게 한다.
  private var silenceWatchdog: DispatchSourceTimer?
  /// Core Audio 콜백과 시작 때 선택한 Zoom 프로세스가 살아 있는지 감시한다.
  /// 콘텐츠의 음량은 읽지 않으므로 0 PCM이 계속 도착하면 정상 경로로 판단한다.
  private var audioCaptureHealthWatchdog: DispatchSourceTimer?
  /// 180초 무음 경계를 처리하는 비동기 작업. 정지 또는 새 녹음 시작 시 이전 작업을
  /// 취소해, 오래된 작업이 새 세션의 문장이나 volatile을 건드리지 못하게 한다.
  private var lectureBoundaryTask: Task<Void, Never>?
  /// 아주 빠르게 끝난 작업과 새로 저장하는 Task 참조가 엇갈리지 않게 식별하는 값.
  /// 완료 콜백은 자신이 아직 현재 작업일 때만 플래그와 참조를 정리한다.
  private var lectureBoundaryTaskID: UUID?
  /// 같은 무음 구간에 타이머가 20초마다 들어와도 경계를 한 번만 만드는 상태다.
  private var lectureBoundaryProcessing = false
  /// 마지막으로 처리한 무음 구간을 그 직전 소리 시각으로 식별한다. 단순 Boolean은
  /// 앱이 잠든 사이 소리가 잠깐 재개돼 타이머가 회복 상태를 못 본 경우 재무장되지
  /// 않는다. 시각을 비교하면 다음 무음 구간은 감시 틱을 놓쳐도 자동으로 구별된다.
  private var lastHandledLectureBoundarySoundAt: Date?
  /// 경계 커밋과 stop의 마지막 문장 정리가 동시에 SentenceReconstructor를 비우지
  /// 못하게 하는 짧은 임계 구역이다. Whisper 대기에는 잡지 않고 실제 상태 변경에만 쓴다.
  private let lectureBoundaryMutationLock = NSLock()
  /// 이어 적기에서 과거 마지막 문장에 강의 종료 표식을 붙이지 않기 위한 이번 시작 오프셋.
  private var currentRecordingStartOffset: Double = 0
  /// 비동기 경계 작업이 자신을 시작시킨 녹음과 현재 녹음이 같은지 확인하는 세대 값.
  private var recordingGeneration = UUID()
  /// 무음 감시가 "직전 틱에도 조용했는지" 기억해 두는 용도. 상태가 바뀔 때만
  /// 로그·알림을 내보내려고 — 20초마다 매번 남기면 강의 쉬는 시간 10분 동안
  /// 30줄씩 쌓인다. stateLock 이 보호한다.
  private var wasSilent = false
  /// 사용자에게 현재 표시한 캡처 경로 장애 종류다. 같은 장애를 5초마다 반복해서
  /// 로그·SSE로 보내지 않고, 종류가 바뀌거나 복구될 때만 갱신한다.
  private var currentAudioCaptureIssue: AudioCaptureIssue?
  /// 콜백 간격이 기준을 넘은 연속 검사 횟수다. 절전 복귀나 한 번의 스케줄 지연으로
  /// 빨간 배너가 번쩍이지 않도록 두 번 연속 확인한 뒤에만 중단으로 확정한다.
  private var consecutiveAudioCallbackStallChecks = 0
  /// Core Audio 프로세스 목록 조회도 Zoom의 짧은 내부 재시작이나 시스템 부하 때 한
  /// 번 비어 보일 수 있다. 실제 대상 소실 역시 두 번 연속 확인해야 사용자 오류로
  /// 승격해, 정상 녹음 중 순간적인 조회 실패가 빨간 배너로 번쩍이지 않게 한다.
  private var consecutiveMissingCaptureTargetChecks = 0
  /// 기본 출력 장치가 마지막으로 바뀐 시각·이름(이어폰 꽂기/빼기 등). 무음 감시가
  /// "왜 조용해졌는지" 문구를 구체적으로 채울 때 참고만 한다 — 이것 자체로는
  /// 아무것도 알리지 않는다(장치가 바뀌어도 캡처가 안 죽는 경우가 더 흔하다).
  private var lastDeviceChangeAt: Date?
  private var lastDeviceChangeName: String?
  /// 마지막 유효 소리 뒤 이 시간이 지나면 하나의 강의가 끝난 것으로 확정한다.
  /// 30초 캡처 이상 경고와 목적이 다르므로 AudioActivityClock의 짧은 기준과 분리한다.
  private static let lectureBoundarySilenceSeconds: TimeInterval = 180
  /// 긴 무음 시점에는 Whisper가 보통 이미 따라잡아 있다. 그래도 실행 중인 한 조각을
  /// 중간에서 자르지 않도록 최대 60초 기다리고, 끝나지 않으면 다음 감시 틱에서 재시도한다.
  private static let lectureBoundaryWhisperWaitSeconds: TimeInterval = 60
  /// Whisper 큐에 들어오기 직전인 AudioArchive의 VAD 분할도 먼저 기다린다. 평소에는
  /// 수백 ms지만 외부 분할 작업이 지연될 때 경계를 앞질러 확정하지 않도록 상한을 둔다.
  private static let lectureBoundaryArchiveWaitSeconds: TimeInterval = 30
  /// 정상 탭은 무음 PCM도 짧은 간격으로 계속 보낸다. 마지막 버퍼가 이 시간보다
  /// 오래됐으면 콘텐츠 무음이 아니라 전달 경로 중단 후보로 본다. 실제 경고 평가는
  /// 5초마다 하므로 순간적인 스케줄 지연 한 번으로 사용자에게 오류를 띄우지 않는다.
  private static let audioCallbackStallSeconds: TimeInterval = 5
  /// 사용자가 정지한 열린 구간이 10분보다 짧으면 오류 복구나 짧은 시험 녹음일 수 있어
  /// 독립적인 요약 단위로 오인되지 않도록 녹음 종료 경계를 붙이지 않는다.
  private static let stopBoundaryMinimumOpenSpanSeconds: TimeInterval = 600

  let stateLock = NSLock()
  var running = false
  /// 진행 중인 로컬 요약. nil이 곧 "요약 중이 아님"이라 별도 플래그가 필요 없다.
  /// stateLock이 보호한다. 두 플래그를 손으로 맞추던 예전 구조가 왜 위험했는지는
  /// `SummaryJob` 주석에 적어 두었다.
  var activeSummaryJob: SummaryJob?
  /// start()가 모델·오디오 장치를 준비하는 동안. stop()은 이 단계가 끝난 뒤 정리한다.
  var starting = false
  /// 오디오와 Whisper를 닫고 디스크에 저장하는 동안. 새 시작·세션 전환을 막는다.
  var stopping = false
  private var resolvedLocale: Locale?
  private var analyzerFormat: AVAudioFormat?
  private var userTerms: [String] = []

  init(options: Options) {
    self.options = options
    self.server = HTTPServer(port: options.port)
  }

  func boot() throws {
    logEnvironment()
    try? FileManager.default.createDirectory(at: effectiveBaseDir, withIntermediateDirectories: true)

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
    log("기본 저장 위치: \(effectiveBaseDir.path)")
    if options.openBrowser { NSWorkspace.shared.open(url) }

    startOutputDeviceWatcher()
    Task { await self.prepareModels() }
  }

  /// 이어폰 꽂기/빼기 등으로 기본 출력 장치가 바뀌는 걸 감지한다. 시작·정지와
  /// 무관하게 앱이 뜬 동안 딱 한 번만 등록해 둔다 — 녹음 중이 아닐 때 온 이벤트는
  /// 콜백 안에서 그냥 걸러낸다.
  ///
  /// 이것 자체로는 아무것도 알리지 않는다 — 장치가 바뀌어도 캡처가 안 죽는 경우가
  /// 더 흔해서, 바뀔 때마다 알리면 오탐이 된다. 그냥 "언제, 무엇으로 바뀌었는지"만
  /// 기억해 뒀다가 `startSilenceWatchdog` 가 진짜 무음을 확인했을 때 문구를
  /// 구체화하는 데만 쓴다.
  private func startOutputDeviceWatcher() {
    CoreAudioInfo.watchDefaultOutputDevice { [weak self] in
      guard let self, self.stateLock.withLock({ self.running }) else { return }
      let name = CoreAudioInfo.defaultOutputName() ?? "알 수 없는 장치"
      self.stateLock.withLock { self.lastDeviceChangeAt = Date(); self.lastDeviceChangeName = name }
      log("오디오 출력 장치 전환 감지 — 지금 기본 출력: \(name)")
    }
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
  func diagJSON() -> [String: Any] {
    var json: [String: Any] = [:]
    let activityClock = stateLock.withLock { audioActivityClock }
    json["framesSeen"] = activityClock?.framesSeen ?? 0
    json["heardSound"] = activityClock?.isHearingSound ?? false
    json["silenceSeconds"] = activityClock?.silenceDuration ?? 0
    // 이 값은 실제 audible sound가 아니라 활성 출력 I/O 존재 여부다. 진단 화면도
    // Core Audio가 보장하지 않는 "재생 중" 의미를 사용자에게 약속하지 않게 한다.
    json["hasActiveOutputIO"] = CoreAudioInfo.hasAnyProcessWithActiveOutputIO()
    let heartbeatSnapshot = stateLock.withLock { audioCaptureHeartbeat }?.snapshot()
    json["captureHasReceivedBuffer"] = heartbeatSnapshot?.hasReceivedAudioBuffer ?? false
    json["secondsSinceCaptureBuffer"] = heartbeatSnapshot?.secondsSinceMostRecentBufferOrStart ?? 0
    json["captureScope"] = tap?.captureScope?.rawValue ?? "-"
    json["sourceFormat"] = tap?.sourceFormat.map { "\($0.sampleRate)Hz ch\($0.channelCount)" } ?? "-"
    json["peak"] = Double(activityClock?.peakLevel ?? 0)
    let db = activityClock?.peakDBFS ?? -Double.infinity
    json["peakDBFS"] = db.isFinite ? db : -120
    json["rms"] = activityClock?.rmsLevel ?? 0
    json["levelAdvice"] = Self.levelAdvice(activityClock, heartbeatSnapshot: heartbeatSnapshot)
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

  /// 콘텐츠 레벨과 콜백 생존 상태를 구분해 진단용 한 줄을 만든다. 0 PCM만으로
  /// 권한 문제라고 단정하거나 전처리를 권하지 않는다. 실제 오류 배너는 별도 캡처
  /// 건강 감시가 콜백 중단 또는 대상 소실을 확인했을 때만 표시한다.
  private static func levelAdvice(
    _ activityClock: AudioActivityClock?,
    heartbeatSnapshot: AudioCaptureHeartbeat.Snapshot?
  ) -> String {
    guard let activityClock, activityClock.framesSeen > 0 else {
      return "아직 오디오가 들어오지 않았습니다."
    }
    guard activityClock.isHearingSound else {
      if let heartbeatSnapshot,
         heartbeatSnapshot.secondsSinceMostRecentBufferOrStart <= audioCallbackStallSeconds {
        return "오디오 버퍼는 정상 수신 중이며 현재 콘텐츠가 무음입니다."
      }
      return "현재 콘텐츠가 무음이며 캡처 콜백 상태는 별도 경로 진단을 확인해야 합니다."
    }
    let db = activityClock.peakDBFS
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
  func shutdown() async {
    // 브라우저가 "종료했습니다" 응답을 받을 틈을 준다.
    try? await Task.sleep(for: .milliseconds(250))

    // 요약을 끊지 않고 프로세스를 끝내면 unload()가 돌지 못해 Qwen 8B가 keep_alive
    // 10분 동안 Ollama 메모리에 남는다. 여기서 기다리지는 않는다 — /api/quit의 8초
    // 워치독 안에 Whisper 정리(최대 180초)도 끝내야 해서, 취소만 걸어 두고 이어지는
    // stop()이 도는 동안 자연스럽게 마무리되게 한다.
    if let summaryJobAtShutdown = stateLock.withLock({ activeSummaryJob }) {
      log("종료 0/3 — 진행 중이던 요약을 취소합니다.")
      summaryJobAtShutdown.cancel()
    }

    log("종료 1/3 — 녹음을 멈추고 저장합니다.")
    // 관리자 A/B probe는 일반 stop() 자원이 아니므로 앱 종료에서 별도로 닫는다.
    // 먼저 닫아 이후 단계에서 Core Audio 집합 장치가 프로세스에 남지 않게 한다.
    _ = administratorAudioProbe.stop()
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
  static func armQuitWatchdog(seconds: Double) {
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

  // MARK: - 라우팅

  /// 들어온 요청을 주제별 묶음에 차례로 물어본다.
  ///
  /// 라우트가 41개라 하나의 `switch` 로 두면 500줄이 넘어가고, 실제로 그 안에서
  /// 관계없는 라우트를 같이 지운 사고가 있었다. 묶음마다 파일을 따로 두고
  /// **nil 이면 '내 담당 아님'** 으로 넘기게 했다 — `switch` 는 파일을 넘을 수 없기 때문이다.
  /// 순서는 자주 불리는 것부터다.
  private func route(_ req: HTTPRequest) async -> Route {
    if let r = await coreRoutes(req)     { return r }
    if let r = await sessionRoutes(req)  { return r }
    if let r = await analysisRoutes(req) { return r }
    if let r = await summaryRoutes(req)  { return r }
    if let r = await adminRoutes(req)    { return r }
    return .response(.notFound)
  }

  // MARK: - 교안 PDF

  func handleDomainUpload(_ req: HTTPRequest) async -> HTTPResponse {
    let name = req.query["name"].map { SessionStore.sanitize($0) } ?? "교안.pdf"
    guard !req.body.isEmpty else {
      return .json(["ok": false, "error": "파일이 비어 있습니다."])
    }

    do {
      // 용어를 뽑는 데만 쓰고 원본 PDF 는 어디에도 남기지 않는다 — 세션 폴더에도,
      // 임시 폴더에도. PDFDocument(data:) 로 메모리에서 바로 열리므로 디스크에 쓸
      // 이유가 없다. 캐시(DomainCache)도 추출된 용어만 담지, PDF 바이트는 안 담는다.
      let t0 = Date()
      let cacheKey = DomainCache.key(for: req.body)
      var entry = DomainCache.load(key: cacheKey)
      let fromCache = entry != nil

      if let hit = entry {
        log("교안 캐시 적중: \(name) — \(hit.pages)쪽, 용어 \(hit.terms.count)개 "
          + "[\(hit.refinedBy)], \(Self.ago(hit.cachedAt)) 분석한 결과")
      } else {
        let result = try DomainKnowledge.analyze(pdf: req.body)

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
  func goldJSON() -> [String: Any] {
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
  func summariesJSON() -> [[String: Any]] {
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

  // MARK: - 상태

  func stateJSON() async -> [String: Any] {
    let segs = store.allSegments.map { segment -> [String: Any] in
      var payload: [String: Any] = [
        "id": segment.id, "start": segment.start, "end": segment.end,
        "text": segment.text, "edited": segment.edited,
      ]
      if let boundary = segment.boundaryAfter {
        payload["boundaryAfter"] = boundary.rawValue
      }
      return payload
    }
    let isRunning = stateLock.withLock { running }
    let engine = await Summarizer.currentEngine()
    let whisper = store.whisperSegments.compactMap { seg -> [String: Any]? in
      // 녹음 중이고 문단화가 작동 중이면, 문단이 아직 안 정해진 꼬리는 새로고침
      // 해도 안 보낸다 — ingestWhisperLines 와 같은 이유(재배치 방지). 정지 후엔
      // finalizeParagraphs 가 전부 확정해 두므로 이 조건에 안 걸린다.
      if isRunning, Paragraph.isReady, seg.paragraph == nil { return nil }
      var d: [String: Any] = ["id": seg.id, "start": seg.start, "end": seg.end,
                               "text": seg.text, "edited": seg.edited]
      // paragraph 는 Int? 라 nil 이면 아예 키를 뺀다. JSONSerialization 이
      // Optional<Int> 를 그대로 못 받아서, nil 을 그냥 넣으면 인코딩이 깨진다.
      if let p = seg.paragraph { d["paragraph"] = p }
      if let boundary = seg.boundaryAfter { d["boundaryAfter"] = boundary.rawValue }
      return d
    }
    // 클립 목록을 한 번만 읽는다. 상태 요청마다 디렉터리를 두 번 훑으면 긴 세션에서
    // 불필요한 파일 시스템 작업이 생기고, 두 조회 사이에 파일이 바뀌면 개수와 용량이
    // 서로 다른 시점의 값이 될 수 있다.
    let archivedAudioClips = store.sessionDir.map { AudioArchive.clips(in: $0) } ?? []
    let archivedAudioBytes = archivedAudioClips.reduce(Int64(0)) { partialBytes, audioClip in
      partialBytes + audioClip.bytes
    }
    var json: [String: Any] = [
      // 화면이 "내가 여기까지 봤다" 를 대조할 기준점. 이벤트를 놓쳤는지 이걸로 안다.
      "seq": live.currentSeq,
      "boot": live.bootID,
      "running": isRunning,
      "summarizing": stateLock.withLock { activeSummaryJob != nil },
      "title": store.title,
      "segments": segs,
      "whisperSegments": whisper,
      "baseDir": options.baseDir.path,
      "storageLocation": effectiveBaseDir.path,
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
      "audioClips": archivedAudioClips.count,
      "audioSeconds": Int(archivedAudioBytes / 32_000),
      "audioMB": Double(archivedAudioBytes) / 1_048_576,
      "audioRetentionStatus": store.audioRetentionStatus?.rawValue ?? "",
      "administratorMode": options.admin,
    ]
    // SSE 진행 이벤트는 durable: false라 새로고침하면 사라진다. 수 분짜리 작업에서
    // "요약 중"이라는 문구만 남고 몇 번째인지 알 수 없으면 사용자가 멈춘 줄 알고
    // 중복 실행을 시도하므로, 마지막 진행률을 상태에 함께 싣는다.
    if let progress = stateLock.withLock({ activeSummaryJob?.progress }), progress.total > 0 {
      json["summaryProgress"] = ["done": progress.completed, "total": progress.total]
    }
    if let sum = store.summary { json["summary"] = sum }
    json["summaryEngine"] = engine.label
    if let summaryEngineNote = store.summaryEngineNote {
      json["summaryEngineNote"] = summaryEngineNote
    }
    if let note = engine.note { json["summarizerNote"] = note }
    return json
  }

  func fileStem() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HHmm"
    return "\(df.string(from: store.createdAt))_\(SessionStore.sanitize(store.title))"
  }

  func autosave() {
    guard store.sessionDir != nil else { return }
    do { try SessionStore.save(store) } catch { logWarn("자동 저장 실패: \(error.localizedDescription)") }
  }

  /// 재구성된 Whisper 문장을 저장하고, 문단을 갱신하고, 화면에 알린다.
  /// `onLines` 콜백과 `stop()`의 마지막 꼬리 처리가 이 로직을 그대로 같이 쓴다.
  private func ingestWhisperLines(_ lines: [WhisperLive.Line], rawTokens: [Whisper.Token] = []) {
    guard !lines.isEmpty else { return }
    let added = store.appendWhisper(lines, rawTokens: rawTokens)
    for seg in added {
      // 그 시각에 실제로 소리가 있었는지 대조한다. 지우지 않고 알리기만 한다 —
      // 아직 근거가 환각 6건뿐이라, 오탐이 없는지 확인하는 단계다.
      // Whisper 가 VAD 로 무음을 안 읽으므로 평소엔 걸릴 게 없다.
      // 그래도 **로그에는 남긴다** — VAD 가 조용히 멈춰도 알 수 있어야 한다.
      if let dir = store.sessionDir,
         let db = AudioSlice.peakDBFS(dir: dir, from: seg.start, to: seg.end),
         db < AudioSlice.quietCeiling {
        logWarn("무음 위에 적힘 — \(TranscriptStore.clock(seg.start)) "
              + "피크 \(String(format: "%.1f", db))dBFS 「\(seg.text.prefix(40))」 "
              + "(VAD 가 안 도는지 확인하세요)")
      }
    }
    // 문단 번호는 문맥이 쌓여야 확정되니, 방금 붙은 줄이 아니라 몇 조각 전에
    // 붙었던 줄에 처음 번호가 매겨지는 경우가 흔하다 — 그 옛 줄도 같이 갱신한다.
    let changedParagraphs = store.regroupParagraphs()

    guard Paragraph.isReady else {
      // 문단화 모델이 아예 안 떴으면(에셋 실패 등) 문단은 영원히 안 정해진다.
      // 그럴 때도 아래처럼 "정해질 때까지 안 보여준다" 를 그대로 하면 자막이
      // 영영 안 뜨는 훨씬 큰 문제가 된다 — 그래서 예전처럼 바로 보여주는 것으로
      // 폴백한다(문단 구분 없이, 문장마다 타임스탬프가 보이는 모양).
      for seg in added {
        live.broadcast(event: "whisperSegment", payload: whisperSegmentPayload(seg))
      }
      autosave()
      return
    }

    // 문단이 이번에 처음 확정된 줄만 화면에 새로 띄운다 — 아직 문맥이 덜 쌓여
    // 문단이 안 정해진 줄(방금 붙은 꼬리 포함)은 여기서 아예 안 보낸다.
    //
    // 예전엔 방금 붙은 줄을 문단 없이 먼저 띄우고, 나중에 문단이 정해지면
    // whisperParagraph 이벤트로 이미 보여준 그 줄을 다시 찾아 타임스탬프를
    // 지웠다 — 그러다 보니 사람이 이미 읽은 줄이 눈앞에서 위 줄과 합쳐지며
    // 재배치되는 문제가 있었다(실제 강의 중 발견). 이제는 문단이 확정된
    // 순간에만, 이미 최종 모양으로 등장한다. 그동안 그 구간은 아래 칸
    // (실시간)이 계속 보여주고 있으니 화면에 빈 자리가 생기지 않는다.
    for seg in changedParagraphs {
      guard seg.paragraph != nil else { continue }
      live.broadcast(event: "whisperSegment", payload: whisperSegmentPayload(seg))
    }
    autosave()
  }

  /// Whisper 문장을 상태 스냅샷과 SSE에서 같은 모양으로 보낸다. 강의 종료 표식을
  /// 추가한 뒤 어떤 경로는 필드를 빼먹는 일을 막기 위해 payload 조립을 한곳에 둔다.
  private func whisperSegmentPayload(_ segment: Segment) -> [String: Any] {
    var payload: [String: Any] = [
      "id": segment.id,
      "start": segment.start,
      "end": segment.end,
      "text": segment.text,
    ]
    if let paragraph = segment.paragraph { payload["paragraph"] = paragraph }
    if let boundary = segment.boundaryAfter { payload["boundaryAfter"] = boundary.rawValue }
    return payload
  }

  // MARK: - 세션 제어

  /// 지금 이 순간 "기본 저장 위치"가 어디인지 — 관리자 모드면 --dir, 아니면 영구 설정.
  var effectiveBaseDir: URL { options.admin ? options.baseDir : StorageLocation.current }

  /// 세션 폴더가 없으면 만들어서 store 에 반영한다. 있으면 그대로 돌려준다.
  /// created 를 같이 돌려주는 이유: 호출부마다 "새로 만들었을 때만" 로그를 남기던
  /// 기존 동작을 유지해야 하기 때문 — 무조건 로그를 찍으면 이어 적기 때도 매번
  /// "세션 폴더: ..." 가 찍혀서 나중에 문제 추적할 때 오히려 헷갈린다.
  @discardableResult
  func ensureSessionDir(override: String? = nil, folder: String? = nil) throws -> (url: URL, created: Bool) {
    if let dir = store.sessionDir { return (dir, false) }
    let parent = (override?.isEmpty == false) ? URL(fileURLWithPath: override!) : effectiveBaseDir
    let dir = try SessionStore.createDir(base: parent, name: folder, title: store.title)
    store.sessionDir = dir
    return (dir, true)
  }

  func start(title: String?, terms: [String],
                     folder: String?, baseDir: String?, retainOriginalAudio: Bool) async throws {
    // 자리는 라우트에서 이미 잡았다(running = true). 여기서 다시 확인하지 않는다.

    // 이 값은 이번 녹음 구간의 수명주기에 고정한다. UI 체크박스는 녹음 중 비활성화되지만
    // HTTP 요청을 직접 보내 값을 바꾸더라도 이미 시작한 구간의 삭제 정책이 바뀌면 안 된다.
    retainOriginalAudioAfterTranscription = retainOriginalAudio

    if options.admin {
      // probe 시작은 녹음 상태를 검사하지만, probe가 돈 뒤 일반 시작 버튼을 누르는
      // 반대 순서도 막아야 두 탭의 수치와 오디오 경로가 섞이지 않는다. 운영 모드에서는
      // controller가 항상 비어 있고, 관리자 모드에서만 기존 측정을 안전하게 닫는다.
      _ = administratorAudioProbe.stop()
    }

    let startsWithAdministratorFeed = stateLock.withLock { adminFeedPending }
    let requestedCaptureScope: AudioCaptureScope = options.admin
      ? .administratorSystemOutput
      : .zoomMeetingOutput
    if !startsWithAdministratorFeed {
      // Zoom 후보가 없다는 사실은 전사기·아카이브·Whisper를 켜기 전에 확인한다.
      // 이 검사는 최종 장치/스트림을 선택하지 않으며, 시작 순서 경쟁에 대비해
      // SystemAudioTap.start도 같은 조건을 다시 확인하고 전역 폴백 없이 실패한다.
      try SystemAudioTap.validateSourceAvailability(for: requestedCaptureScope)
    }

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
    let (_, created) = try ensureSessionDir(override: baseDir, folder: folder)
    if created { log("세션 폴더: \(store.sessionDir!.path)") }
    let recordingStartOffset = store.timeBase

    // 실제 탭과 관리자 되먹임 모두 아래의 같은 sink를 지나므로, 활동 시계도 여기서
    // 딱 한 번 관측한다. 탭 내부에서도 재면 프레임 수와 RMS 표본이 두 배로 집계된다.
    let activityClock = AudioActivityClock()
    let newRecordingGeneration = UUID()
    let previousBoundaryTask = stateLock.withLock { () -> Task<Void, Never>? in
      let previousTask = lectureBoundaryTask
      lectureBoundaryTask = nil
      lectureBoundaryTaskID = nil
      audioActivityClock = activityClock
      currentRecordingStartOffset = recordingStartOffset
      recordingGeneration = newRecordingGeneration
      lectureBoundaryProcessing = false
      lastHandledLectureBoundarySoundAt = nil
      return previousTask
    }
    previousBoundaryTask?.cancel()

    // 사용자가 적은 용어 + 교안에서 뽑은 용어
    let allTerms = Array((terms + store.domainTerms).reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }.prefix(DomainKnowledge.maxContextualTerms))

    let lecture = TrackTranscriber()
    do {
      try await lecture.start(locale: locale, audioFormat: format, contextualStrings: allTerms,
                              onFinal: { [store] s, e, t, w in
                                store.appendFinal(track: .lecture, start: s, end: e, text: t,
                                                  words: w) },
                              onVolatile: { [store] t in
                                store.setVolatile(track: .lecture, text: t)
                              })
    } catch {
      // 전사기 준비가 실패하면 아직 탭은 없지만 활동 시계는 이미 새 세대로 바뀌어
      // 있다. 이 참조가 그대로 남으면 다음 진단이 시작하지 않은 녹음을 현재 입력처럼
      // 보므로, 자신이 설치한 시계일 때만 되돌린다.
      stateLock.withLock {
        if audioActivityClock === activityClock { audioActivityClock = nil }
      }
      await lecture.finish()
      throw error
    }
    lectureTranscriber = lecture

    // 정확한 Whisper 기록에는 오디오 아카이브가 필수다. 사용자가 선택하는 것은 녹음
    // 여부가 아니라 Whisper 완료 뒤 원본 WAV를 남길지뿐이므로, 보관 선택과 무관하게
    // 항상 같은 처리 파일을 만든다. 파일 생성에 실패해도 Apple 실시간 전사는 계속하되,
    // 위쪽 Whisper 칸에는 실패 이유를 분명히 표시한다.
    var clip: AudioArchive?
    stateLock.withLock { whisperLiveNote = Whisper.isReady ? nil : Whisper.status.detail }
    if let dir = store.sessionDir {
      do {
        clip = try AudioArchive(dir: dir, startOffset: store.timeBase)
        log("Whisper 처리용 소리 기록: \(clip!.url.lastPathComponent) "
          + "(16kHz mono, 시간당 약 110MB, 종료 뒤 보관=\(retainOriginalAudio))")

        // 이 파일은 정확한 자막을 만드는 처리 입력이다. 보관 정책은 Whisper가 끝난 뒤
        // stop()에서 적용하므로, 여기서는 두 선택 모두 같은 전사 경로를 지난다.
        if Whisper.isReady {
          // 문단화 모델도 같이 준비한다. Whisper 없이는 문단화도 의미가 없어 여기서만 싣는다.
          // 로드가 늦어도 자막은 안 막힌다 — 준비되기 전까지는 문장 단위로 그대로 나간다.
          Task { await Paragraph.prepare() }
          let reconstructor = SentenceReconstructor()
          sentenceBuffer = reconstructor
          let worker = WhisperLive(
            prompt: allTerms.prefix(60).joined(separator: ", "),
            onLines: { [weak self] lines in
              guard let self else { return }
              // Whisper 청크가 끊어 준 줄을 그대로 쓰지 않고, 마침표 기준 문장으로
              // 다시 짜 맞춘 뒤에 저장한다(SentenceReconstructor 헤더 참고). 토큰
              // (확신도)은 재구성 전 원본 줄에만 있으므로 따로 모아 같이 넘긴다.
              self.ingestWhisperLines(reconstructor.reconstruct(lines),
                                      rawTokens: lines.flatMap(\.tokens))
            },
            onProgress: { [weak self] done, total in
              self?.live.broadcast(event: "whisperLive",
                             payload: ["done": done, "total": total], durable: false)
            })
          whisperLive = worker
          clip!.onChunk = { [weak worker] url, start in worker?.enqueue(url: url, start: start) }
          log("Whisper 뒤늦은 재전사 켬 — \(Int(AudioArchive.chunkTargetSeconds))초 조각, "
            + "\(Int(AudioArchive.releaseDelaySeconds))초 지난 뒤부터, "
            + "모델 \(Whisper.modelPath?.lastPathComponent ?? "?")")
        } else {
          log("Whisper 를 쓸 수 없어 실시간 재전사는 건너뜁니다 — \(Whisper.status.detail)")
        }
      } catch {
        // 처리 파일 생성이 실패하면 Whisper 로 넘길 조각도 만들 수 없다.
        // 위 칸이 조용히 비어 있는 게 아니라 이유가 보여야 한다.
        logWarn("Whisper 처리용 소리를 기록하지 못했습니다: \(error.localizedDescription)")
        clip = nil
        stateLock.withLock {
          whisperLiveNote = "처리용 소리를 기록하지 못해 Whisper 를 돌릴 수 없습니다 — \(error.localizedDescription)"
        }
        live.broadcast(event: "status", payload: [
          "message": "오디오 처리 실패로 Whisper 자막이 만들어지지 않습니다: \(error.localizedDescription)",
          "level": "warn"])
      }
    }
    live.broadcast(event: "whisperLive", payload: [
      "done": 0, "total": 0, "note": stateLock.withLock { whisperLiveNote } ?? ""])
    archive = clip

    // var인 `clip`을 @Sendable 오디오 콜백에서 직접 잡으면, 이후 값이 바뀔 수 있는
    // 캡처로 취급된다. 준비가 끝난 이 시점의 아카이브를 의미가 드러나는 let으로
    // 고정해 콜백 전체가 한 녹음 파일만 쓰게 한다.
    let recordingAudioArchive = clip
    let sink: @Sendable (AVAudioPCMBuffer) -> Void = { [weak lecture] audioBuffer in
      activityClock.observe(audioBuffer)
      lecture?.feed(audioBuffer)
      recordingAudioArchive?.write(audioBuffer)
    }
    audioSink = sink

    // 관리자 모드에서는 파일 되먹임으로 소리를 넣을 수 있어야 하므로 탭 없이도 시작한다.
    if startsWithAdministratorFeed {
      stateLock.withLock {
        adminFeedPending = false
        audioCaptureHeartbeat = nil
        currentAudioCaptureIssue = nil
        consecutiveAudioCallbackStallChecks = 0
        consecutiveMissingCaptureTargetChecks = 0
      }
      // 되먹임은 실제 탭 시작이 없으므로 sink까지 모두 준비된 이 지점을 녹음 시작으로
      // 확정한다. 파일 입력이 끝난 뒤에도 기존 180초 경계를 시험할 수 있어야 한다.
      store.beginRecording()
      live.broadcast(event: "status", payload: [
        "running": true,
        "message": "",
        "silent": false,
      ])
      // 관리자 파일 되먹임도 실제 캡처와 같은 180초 무음 감시를 거친다. 시험 파일이
      // 끝난 뒤 녹음은 계속 살아 있으므로, 마지막 유효 샘플 기준으로 경계가 발생한다.
      startSilenceWatchdog()
      log("녹음 시작 (관리자 되먹임) — \(store.title)")
      return
    }

    let captureHeartbeat = AudioCaptureHeartbeat()
    let audioTap = SystemAudioTap(captureHeartbeat: captureHeartbeat, onBuffer: sink)
    do {
      // 관리자 모드면 Zoom 만이 아니라 시스템 전체 소리를 듣는다.
      // 표본 오디오를 아무 재생기로 틀어도 잡히므로 Zoom 없이 시험할 수 있다.
      try audioTap.start(scope: requestedCaptureScope)
    } catch {
      // 탭 시작은 전체 시작 transaction의 마지막 실패 지점이다. 여기서 일부 참조를
      // 남기면 HTTP 상태는 idle인데 Whisper·아카이브가 살아 있는 반쪽 세션이 된다.
      // 부분 생성된 탭부터 닫아 새 입력을 막고, 워커·아카이브·전사기 순서로 정리한
      // 뒤 공유 상태를 되돌린다.
      audioTap.stop()
      whisperLive?.cancel()
      whisperLive = nil
      sentenceBuffer = nil
      clip?.onChunk = nil
      _ = await clip?.finish()
      archive = nil
      await lecture.finish()
      lectureTranscriber = nil
      audioSink = nil
      stateLock.withLock {
        if audioActivityClock === activityClock { audioActivityClock = nil }
        audioCaptureHeartbeat = nil
        currentAudioCaptureIssue = nil
        consecutiveAudioCallbackStallChecks = 0
        consecutiveMissingCaptureTargetChecks = 0
      }
      throw error
    }
    tap = audioTap
    stateLock.withLock {
      audioCaptureHeartbeat = captureHeartbeat
      currentAudioCaptureIssue = nil
      consecutiveAudioCallbackStallChecks = 0
      consecutiveMissingCaptureTargetChecks = 0
    }
    // 실제 탭이 성공한 뒤에만 Store의 녹음 시계를 연다. 실패 rollback에서
    // endRecording()을 호출해 이어 적기 기준이 불필요하게 2초 늘어나는 일을 막는다.
    store.beginRecording()

    // running 은 라우트에서 이미 세웠다. 여기서는 화면에만 알린다.
    live.broadcast(event: "status", payload: [
      "running": true,
      "message": "",
      "silent": false,
    ])
    startSilenceWatchdog()
    startAudioCaptureHealthWatchdog()

    log("녹음 시작 — \(store.title)\(store.timeBase > 0 ? " (이어 적기, \(TranscriptStore.clock(store.timeBase))부터)" : "")")
  }

  /// PCM 콘텐츠의 무음과 180초 강의 경계만 감시한다.
  ///
  /// Zoom의 `isRunningOutput`은 실제 소리가 있다는 뜻이 아니므로 이 함수에서는 더
  /// 이상 읽지 않는다. 30초 이상 0 PCM이 계속 도착하는 것은 정상 침묵이며 로그만
  /// 남긴다. 빨간 오류 배너는 별도의 `startAudioCaptureHealthWatchdog()`가 콜백 중단
  /// 또는 캡처 대상 소실을 확인했을 때만 표시한다.
  private func startSilenceWatchdog() {
    stateLock.withLock {
      // 새 녹음 구간은 콘텐츠 무음과 강의 경계 상태를 깨끗하게 시작한다.
      wasSilent = false
      lectureBoundaryProcessing = false
      lastHandledLectureBoundarySoundAt = nil
    }

    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 12, repeating: 20)
    timer.setEventHandler { [weak self] in
      guard let self,
            self.stateLock.withLock({ self.running }),
            let activityClock = self.stateLock.withLock({ self.audioActivityClock }),
            activityClock.framesSeen > 0
      else { return }

      // 아직 유효한 소리를 한 번도 듣지 못했다면 무음의 시작점을 정할 수 없다.
      // `isHearingSound == false`만 쓰면 첫 12초 감시 틱에서 곧바로 "30초 무음"을
      // 기록하므로, 실제 마지막 소리 시각이 있는 경우에만 30초 경과를 판정한다.
      guard let currentSilenceDuration = activityClock.silenceDuration else { return }
      let silentNow = currentSilenceDuration >= AudioActivityClock.recentSoundWindow
      let wasSilentBefore = self.stateLock.withLock { () -> Bool in
        let prev = self.wasSilent
        self.wasSilent = silentNow
        return prev
      }

      guard silentNow else {
        if wasSilentBefore {   // 방금 회복된 그 틱에서만 한 번
          log("콘텐츠 무음 종료 — 다시 유효한 소리가 들어오고 있습니다.")
          // 강의 경계의 재무장은 아래 beginLectureBoundaryIfNeeded가 마지막 유효
          // 소리 시각을 비교해 자동 처리한다. 오류 배너는 캡처 건강 감시만 관리한다.
        }
        return
      }

      if !wasSilentBefore {
        log("30초 이상 콘텐츠 무음 — 오디오 콜백 상태와 별개로 정상 침묵으로 처리합니다.")
      }

      // 실제 탭의 콜백이 끊겼다면 시간이 180초 흘러도 강의 침묵으로 확정하지 않는다.
      // 관리자 되먹임은 파일 끝 뒤에 콜백이 없는 것이 정상이고 바로 이 경로를 시험하는
      // 용도이므로 tap이 없는 경우에는 기존 180초 동작을 그대로 허용한다.
      guard self.hasHealthyCaptureDeliveryForLectureBoundary() else { return }

      if let silencePeriod = activityClock.silencePeriod,
         silencePeriod.duration >= Self.lectureBoundarySilenceSeconds {
        self.beginLectureBoundaryIfNeeded(activityClock: activityClock,
                                          silencePeriod: silencePeriod)
      }
    }
    timer.resume()
    silenceWatchdog = timer
  }

  /// 180초가 실제 콘텐츠 침묵으로 관측됐는지 확인한다. 탭이 없는 관리자 되먹임은
  /// 파일 입력 종료 뒤에도 경계 시험을 계속해야 하므로 true다. 실제 탭에서는 대상
  /// 프로세스가 남아 있고 최근 콜백이 도착한 경우에만 강의 경계를 허용한다.
  private func hasHealthyCaptureDeliveryForLectureBoundary() -> Bool {
    guard let currentAudioTap = tap else { return true }
    guard currentAudioTap.hasAvailableCapturedTarget,
          let captureHeartbeat = stateLock.withLock({ audioCaptureHeartbeat })
    else { return false }
    return captureHeartbeat.snapshot().secondsSinceMostRecentBufferOrStart
      <= Self.audioCallbackStallSeconds
  }

  /// 실제 탭의 전달 경로만 5초마다 검사한다. PCM이 0인지 아닌지는 전혀 보지 않기
  /// 때문에 발표자 침묵은 정상으로 남고, 버퍼 자체가 멈추거나 시작 때 선택한 Zoom
  /// 프로세스가 모두 사라진 경우에만 사용자에게 오류를 알린다.
  private func startAudioCaptureHealthWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler { [weak self] in
      guard let self,
            self.stateLock.withLock({ self.running && !self.stopping }),
            let currentAudioTap = self.tap,
            let captureHeartbeat = self.stateLock.withLock({ self.audioCaptureHeartbeat })
      else { return }

      let heartbeatSnapshot = captureHeartbeat.snapshot()
      let callbackAppearsStalled = heartbeatSnapshot.secondsSinceMostRecentBufferOrStart
        > Self.audioCallbackStallSeconds
      let captureTargetIsAvailable = currentAudioTap.hasAvailableCapturedTarget
      let confirmedHealthState = self.stateLock.withLock { () -> (
        callbackStalled: Bool, captureTargetMissing: Bool
      ) in
        if callbackAppearsStalled {
          self.consecutiveAudioCallbackStallChecks += 1
        } else {
          self.consecutiveAudioCallbackStallChecks = 0
        }
        if captureTargetIsAvailable {
          self.consecutiveMissingCaptureTargetChecks = 0
        } else {
          self.consecutiveMissingCaptureTargetChecks += 1
        }
        return (
          self.consecutiveAudioCallbackStallChecks >= 2,
          self.consecutiveMissingCaptureTargetChecks >= 2
        )
      }
      let detectedIssue: AudioCaptureIssue?
      if confirmedHealthState.captureTargetMissing {
        detectedIssue = .targetProcessLost
      } else if captureTargetIsAvailable && confirmedHealthState.callbackStalled {
        let outputDeviceChangedRecently = self.stateLock.withLock {
          self.lastDeviceChangeAt.map { Date().timeIntervalSince($0) < 60 } == true
        }
        detectedIssue = outputDeviceChangedRecently ? .outputRouteChanged : .callbackStalled
      } else {
        detectedIssue = nil
      }

      let previousIssue = self.stateLock.withLock { () -> AudioCaptureIssue? in
        let previousIssue = self.currentAudioCaptureIssue
        self.currentAudioCaptureIssue = detectedIssue
        return previousIssue
      }
      guard previousIssue != detectedIssue else { return }

      guard let detectedIssue else {
        if previousIssue != nil {
          log("오디오 캡처 경로 복구 — Core Audio 버퍼가 다시 들어오고 있습니다.")
          self.live.broadcast(event: "status", payload: ["silent": false])
        }
        return
      }

      let issueMessage: String
      switch detectedIssue {
      case .targetProcessLost:
        issueMessage = "녹음을 시작할 때 선택한 Zoom 오디오 프로세스가 종료되었습니다. "
          + "시스템 전체 소리로 전환하지 않았습니다. Zoom 회의 상태를 확인한 뒤 녹음을 다시 시작해 주세요."
      case .outputRouteChanged:
        let changedOutputName = self.stateLock.withLock { self.lastDeviceChangeName }
        issueMessage = "오디오 출력 장치가 \(changedOutputName ?? "다른 장치")로 바뀐 뒤 "
          + "Core Audio 버퍼가 들어오지 않습니다. 녹음을 다시 시작해 주세요."
      case .callbackStalled:
        let stalledSeconds = Int(heartbeatSnapshot.secondsSinceMostRecentBufferOrStart.rounded())
        issueMessage = "Core Audio 버퍼가 \(stalledSeconds)초 동안 들어오지 않았습니다. "
          + "Zoom 회의와 화면 및 시스템 오디오 기록 권한을 확인한 뒤 녹음을 다시 시작해 주세요."
      }
      logWarn("오디오 캡처 경로 이상 — \(issueMessage)")
      // `silentMessage`는 기존 빨간 배너 전용 필드 이름을 호환성 때문에 유지하지만,
      // 이제 단순 무음이 아니라 확인된 캡처 경로 장애에만 true를 보낸다.
      self.live.broadcast(event: "status", payload: [
        "silent": true,
        "silentMessage": issueMessage,
      ])
    }
    timer.resume()
    audioCaptureHealthWatchdog = timer
  }

  /// 같은 180초 무음에서 하나의 경계 작업만 시작한다. 실제 처리는 비동기로 돌려
  /// 감시 타이머 큐를 막지 않는다. `recordingGeneration`과 작업 ID를 함께 캡처해
  /// 정지·재시작 경계에서 오래된 작업이 새 세션을 변경하지 못하게 한다.
  private func beginLectureBoundaryIfNeeded(activityClock: AudioActivityClock,
                                            silencePeriod: AudioActivityClock.SilencePeriod) {
    let boundaryTaskID = UUID()
    let claimedContext: (generation: UUID, recordingStartOffset: Double)? = stateLock.withLock {
      guard running, !starting, !stopping,
            !lectureBoundaryProcessing,
            lastHandledLectureBoundarySoundAt != silencePeriod.lastNonSilentAt
      else { return nil }

      lectureBoundaryProcessing = true
      lectureBoundaryTaskID = boundaryTaskID
      return (recordingGeneration, currentRecordingStartOffset)
    }
    guard let claimedContext else { return }

    let boundaryTask = Task { [weak self] in
      guard let self else { return }
      let boundaryWasApplied = await self.applyLectureBoundary(
        activityClock: activityClock,
        silencePeriod: silencePeriod,
        recordingGeneration: claimedContext.generation,
        recordingStartOffset: claimedContext.recordingStartOffset)

      self.stateLock.withLock {
        // 이 작업이 끝나는 사이 stop/start가 새 작업을 세웠다면 그 상태는 건드리지 않는다.
        guard self.lectureBoundaryTaskID == boundaryTaskID else { return }
        self.lectureBoundaryProcessing = false
        if boundaryWasApplied {
          self.lastHandledLectureBoundarySoundAt = silencePeriod.lastNonSilentAt
        }
        self.lectureBoundaryTask = nil
        self.lectureBoundaryTaskID = nil
      }
    }

    stateLock.withLock {
      // 유휴 Whisper라 작업이 매우 빨리 끝난 경우 완료 쪽에서 ID를 이미 지웠을 수 있다.
      // 그때 완료된 Task 참조를 다시 저장하지 않는다.
      if lectureBoundaryTaskID == boundaryTaskID {
        lectureBoundaryTask = boundaryTask
      } else {
        boundaryTask.cancel()
      }
    }
  }

  /// 긴 무음 직전의 Whisper 꼬리와 문단을 확정하고 강의 종료 표식을 저장한다.
  /// 반환값이 false면 어떤 경계 상태도 확정하지 않았다는 뜻이며, 감시 타이머가 다음
  /// 틱에서 다시 시도할 수 있다.
  private func applyLectureBoundary(activityClock: AudioActivityClock,
                                    silencePeriod: AudioActivityClock.SilencePeriod,
                                    recordingGeneration expectedRecordingGeneration: UUID,
    recordingStartOffset: Double) async -> Bool {
    if let recordingArchive = archive {
      let pendingAudioWasReleased = await recordingArchive.flushPendingForLectureBoundary(
        timeout: Self.lectureBoundaryArchiveWaitSeconds)
      guard pendingAudioWasReleased else {
        if !Task.isCancelled {
          logWarn("180초 무음 경계 보류 — 남은 오디오 조각을 아직 안전하게 방출할 수 없어 다음 감시 주기에 다시 시도합니다.")
        }
        return false
      }
    }

    if let whisperWorker = whisperLive {
      let whisperBecameIdle = await whisperWorker.waitUntilIdle(
        timeout: Self.lectureBoundaryWhisperWaitSeconds)
      guard whisperBecameIdle else {
        if !Task.isCancelled {
          logWarn("180초 무음 경계 보류 — Whisper가 아직 작업 중이라 다음 감시 주기에 다시 시도합니다.")
        }
        return false
      }
    }

    return commitLectureBoundary(
      activityClock: activityClock,
      silencePeriod: silencePeriod,
      recordingGeneration: expectedRecordingGeneration,
      recordingStartOffset: recordingStartOffset)
  }

  /// 비동기 Whisper 대기 뒤의 실제 상태 변경을 한 임계 구역에서 수행한다. stop도 이
  /// 락을 통과한 뒤 최종 flush를 시작하므로, 작업 Task 참조가 저장되기 전 stop과
  /// 엇갈리는 극단적인 경우에도 pending 문장을 두 스레드가 동시에 비우지 않는다.
  private func commitLectureBoundary(activityClock: AudioActivityClock,
                                     silencePeriod: AudioActivityClock.SilencePeriod,
                                     recordingGeneration expectedRecordingGeneration: UUID,
                                     recordingStartOffset: Double) -> Bool {
    lectureBoundaryMutationLock.withLock {
      guard !Task.isCancelled else { return false }
      let stillCurrentRecording = stateLock.withLock {
        running && !stopping
          && recordingGeneration == expectedRecordingGeneration
          && audioActivityClock === activityClock
      }
      guard stillCurrentRecording,
            activityClock.hasMaintainedSilence(
              silencePeriod, forAtLeast: Self.lectureBoundarySilenceSeconds)
      else {
        // Whisper를 기다리는 동안 새 소리가 들어왔다면 오래된 volatile이나 문단을
        // 건드리지 않는다. 새 소리가 다시 180초 멎었을 때 새 스냅샷으로 재시도한다.
        return false
      }

      // Whisper 워커의 onLines 콜백이 끝나 유휴가 된 뒤이므로, 여기서 pending을
      // 비우면 무음 전 마지막 조각과 무음 후 새 강의가 한 문장으로 합쳐지지 않는다.
      if let pendingSentenceLines = sentenceBuffer?.flushPendingForLectureBoundary(),
         !pendingSentenceLines.isEmpty {
        ingestWhisperLines(pendingSentenceLines)
      }

      // 문단 모델이 오른쪽 문맥을 기다리며 숨겨 둔 마지막 문장들도 현재 정보만으로
      // 확정한다. 다음 Whisper 문장은 Store가 기억한 경계 ID 때문에 새 문단이 된다.
      for finalizedSegment in store.finalizeParagraphsForLectureBoundary() {
        guard finalizedSegment.paragraph != nil else { continue }
        live.broadcast(event: "whisperSegment",
                       payload: whisperSegmentPayload(finalizedSegment))
      }

      let boundaryUpdate = store.markLatestSegmentAsLectureEnded(after: recordingStartOffset)
      if let boundaryUpdate {
        live.broadcast(event: "lectureBoundary", payload: [
          "collection": boundaryUpdate.collection.rawValue,
          "id": boundaryUpdate.segment.id,
          "boundaryAfter": TranscriptBoundary.lectureEnded.rawValue,
        ])
      }

      // 위의 동기 작업 사이에 새 강의가 시작되면 그 새 volatile을 비우면 안 된다.
      // 180초 경계와 문단 확정은 첫 재검사 시점에 이미 유효했으므로 유지하되, 임시
      // 문구만 두 번째 재검사 결과가 true일 때 지운다.
      let sameSilenceStillActive = activityClock.hasMaintainedSilence(
        silencePeriod, forAtLeast: Self.lectureBoundarySilenceSeconds)
      if sameSilenceStillActive {
        store.clearVolatileAtLectureBoundary(track: .lecture)
      } else {
        log("강의 경계 확정 직후 새 소리가 들어와 현재 volatile은 유지합니다.")
      }
      autosave()

      if boundaryUpdate != nil {
        log("180초 연속 무음 — Whisper 꼬리와 문단을 확정하고 마지막 문장에 강의 종료 경계를 기록했습니다.")
      } else {
        // 유효 소리는 있었지만 두 전사기가 영속 문장을 하나도 만들지 못한 경우다.
        // 붙일 문장을 임의로 만들지 않고 꼬리 정리와 volatile clear만 수행한다.
        log("180초 연속 무음 — 영속 문장이 없어 강의 종료 표식은 생략했습니다.")
      }
      live.broadcast(event: "status", payload: [
        "message": "3분 무음으로 강의 한 단위를 마무리했습니다. 녹음은 계속됩니다.",
        "level": "info",
      ])
      return true
    }
  }

  @discardableResult
  func stop() async -> String? {
    // 시작 준비와 정지가 같은 자원을 만지지 않게 직렬화한다. 시작 중 들어온 정지는
    // start()가 성공하거나 실패해 starting을 내릴 때까지 기다린 뒤 정리한다.
    while stateLock.withLock({ starting }) {
      try? await Task.sleep(for: .milliseconds(50))
    }

    let claimed = stateLock.withLock { () -> Bool in
      guard !stopping else { return false }
      stopping = true
      return true
    }
    guard claimed else {
      // 다른 요청이 이미 정리 중이면 같은 자원을 두 번 닫지 않고 그 작업만 기다린다.
      while stateLock.withLock({ stopping }) {
        try? await Task.sleep(for: .milliseconds(50))
      }
      return nil
    }

    let wasRunning = stateLock.withLock { running }
    // startedAt도 본다. 시작 도중 실패해 장치 참조는 사라졌지만 세션 시계가 남은
    // 경우까지 endRecording()으로 닫아야 한다. 단순히 저장된 기록이 있다는 이유만으로
    // 이미 끝난 세션을 매번 다시 종료해 timeBase를 늘리지는 않는다.
    let hasWork = tap != nil || lectureTranscriber != nil || archive != nil
      || whisperLive != nil || adminFeed.isRunning || store.startedAt != nil
    guard wasRunning || hasWork else {
      stateLock.withLock { stopping = false }
      return nil
    }
    if !wasRunning { logWarn("running 플래그가 꺼져 있었지만 남은 기록을 정리해 저장합니다.") }

    // running은 저장이 끝날 때까지 true로 유지한다. 그래야 다른 탭의 시작·세션 전환
    // 요청도 기존 guard에서 계속 막힌다. 새 시작이 끼어들 수 없는 상태에서 stopped
    // 이벤트를 먼저 보낸 다음 idle로 전환한다.
    defer {
      stateLock.withLock { running = false }
      // 캡처 장애 배너가 떠 있던 상태에서 정지해도 다음 세션 화면에 남지 않게
      // running과 배너 상태를 같은 마지막 이벤트로 되돌린다.
      live.broadcast(event: "status", payload: ["running": false, "silent": false])
      live.broadcast(event: "volatile",
                     payload: ["track": Track.lecture.rawValue, "text": ""], durable: false)
      stateLock.withLock { stopping = false }
    }

    silenceWatchdog?.cancel(); silenceWatchdog = nil
    audioCaptureHealthWatchdog?.cancel(); audioCaptureHealthWatchdog = nil
    let boundaryTaskToCancel = stateLock.withLock { () -> Task<Void, Never>? in
      let task = lectureBoundaryTask
      lectureBoundaryTask = nil
      lectureBoundaryTaskID = nil
      lectureBoundaryProcessing = false
      lastHandledLectureBoundarySoundAt = nil
      audioActivityClock = nil
      audioCaptureHeartbeat = nil
      currentAudioCaptureIssue = nil
      consecutiveAudioCallbackStallChecks = 0
      consecutiveMissingCaptureTargetChecks = 0
      return task
    }
    boundaryTaskToCancel?.cancel()
    // 취소 신호만 보내고 바로 sentenceBuffer를 finalize하면 두 작업이 같은 pending을
    // 동시에 비울 수 있다. 작업 종료까지 짧게 기다린 뒤 정지 마무리를 시작한다.
    await boundaryTaskToCancel?.value
    // beginLectureBoundaryIfNeeded가 Task 참조를 저장하기 직전에 stop과 엇갈린 경우엔
    // 위에서 기다릴 참조가 없을 수 있다. 실제 변경 임계 구역을 한 번 통과해 그 경로까지 막는다.
    lectureBoundaryMutationLock.withLock { }
    tap?.stop(); tap = nil
    adminFeed.stop()

    // 탭을 멈춘 뒤에 닫아야 마지막 버퍼까지 들어간다.
    // finish() 안에서 자투리가 마지막 조각으로 나가므로 Whisper 를 기다리는 건 그다음이다.
    let completedAudioArchive = await archive?.finish()
    if let completedAudioArchive {
      log(String(format: "Whisper 처리용 소리 기록 완료: %@ — %.0f초, %.1fMB",
                 completedAudioArchive.url.lastPathComponent, completedAudioArchive.seconds,
                 Double(completedAudioArchive.bytes) / 1_048_576))
    }
    archive = nil

    // 열린 구간은 문단이 아니라 이전 구조화 경계부터 재야 한다. 문단은 녹음 중에도
    // 계속 확정되어 길이를 몇 초로 축소하므로, 강제 문단화 전에 경계 기준을 보존한다.
    let openSpanReferencePoint: Double
    var whisperProcessingCompletedSuccessfully = false
    if let worker = whisperLive {
      let (done, total) = worker.progress
      if done < total {
        log("Whisper 남은 조각 \(total - done)개를 마저 처리합니다.")
        live.broadcast(event: "status", payload: [
          "message": "Whisper 가 마지막 구간을 정리하는 중입니다…", "level": "info"])
      }
      whisperProcessingCompletedSuccessfully = await worker.finish()
      if !whisperProcessingCompletedSuccessfully {
        // 자동 삭제를 골랐더라도 Whisper 실패나 시간 초과가 있었다면 원본이 유일한
        // 복구 수단이다. 아래 보관 정책이 이 값을 보고 파일을 지우지 않는다.
        logWarn("Whisper 처리가 완전히 성공하지 않아 원본 소리를 보존합니다.")
      }
      // 마침표를 못 만나 문장으로 못 묶고 대기 중이던 꼬리 — 더 올 줄이 없으니 그대로 확정.
      if let tail = sentenceBuffer?.finalize(), !tail.isEmpty {
        ingestWhisperLines(tail)
      }
      sentenceBuffer = nil
      log("Whisper 실시간 재전사 종료 — 조각 \(worker.progress.done)개, \(store.whisperSegments.count)줄")
      whisperLive = nil
      // 이전 경계만 조회해야 실시간 문단 확정 횟수와 무관하게 마지막으로 닫힌 기록
      // 단위 이후의 전체 길이를 보존하고, 10분 정지 기준이 영원히 충족되지 않는 일을 막는다.
      openSpanReferencePoint =
        store.lastClosedTranscriptUnitEnd(after: currentRecordingStartOffset)
        ?? currentRecordingStartOffset
      // 마지막 2~3문장은 앞으로 문맥이 더 쌓일 일이 없다 — 대기하던 판정을 여기서 확정한다.
      // ingestWhisperLines 가 문단 없는 줄은 화면에 아예 안 띄워 왔으므로(재배치 방지),
      // 여기서 나오는 줄들은 전부 처음 등장하는 것이다 — 그래서 whisperSegment 로
      // 온전히 보낸다(whisperParagraph 는 이미 떠 있는 줄을 갱신하는 용도라 안 맞는다).
      for seg in store.finalizeParagraphs() {
        guard seg.paragraph != nil else { continue }
        live.broadcast(event: "whisperSegment", payload: whisperSegmentPayload(seg))
      }
    } else {
      // Whisper가 없으면 이번 구간의 정식 기록 경계도 없으므로 시작점을 써야 하며,
      // 이어 적기 전 세션의 경계를 현재 열린 구간의 시작으로 잘못 가져오지 않는다.
      openSpanReferencePoint = currentRecordingStartOffset
    }

    await lectureTranscriber?.finish(); lectureTranscriber = nil
    audioSink = nil

    // 정지 직전의 실제 전사 끝만 보고 10분 이상 열린 구간에 표식을 붙인다. 이번 녹음
    // 오프셋 검사는 이어 적기 후 발화가 없을 때 과거 세션의 마지막 문장을 오염시키지 않는다.
    if let lastContentEnd = store.primarySegments.last(where: {
      $0.end >= currentRecordingStartOffset
    })?.end,
       lastContentEnd - openSpanReferencePoint >= Self.stopBoundaryMinimumOpenSpanSeconds {
      let boundaryUpdate = store.markLatestSegmentAsLectureEnded(
        after: currentRecordingStartOffset,
        reason: .recordingStopped)
      if let boundaryUpdate {
        // 저장소 변경만으로는 이미 열린 브라우저가 이유를 알 수 없으므로 구조화 값을
        // 함께 보내며, 재동기화 전에도 강의 종료와 녹음 종료를 정확히 구분하게 한다.
        live.broadcast(event: "lectureBoundary", payload: [
          "collection": boundaryUpdate.collection.rawValue,
          "id": boundaryUpdate.segment.id,
          "boundaryAfter": TranscriptBoundary.recordingStopped.rawValue,
        ])
      }
    }

    store.endRecording()

    guard !store.isEmpty else { log("기록이 비어 있어 저장하지 않음"); return nil }
    do {
      // 세션 폴더가 없으면(예: 시작 도중 실패) 여기서 만들어서라도 남긴다.
      let (madeDir, created) = try ensureSessionDir()
      if created { log("세션 폴더가 없어 새로 만들었습니다: \(madeDir.lastPathComponent)") }

      // 삭제보다 세션 저장이 반드시 먼저다. 자막과 상태 파일을 안전하게 디스크에 쓴
      // 뒤에만 원본을 지워, 저장 실패와 삭제 성공이 겹쳐 복구 자료를 모두 잃는 경우를
      // 만들지 않는다. Whisper 실패·시간 초과 때도 사용자 선택보다 복구 가능성을 우선한다.
      if completedAudioArchive != nil {
        let retentionStatusBeforeSaving: AudioRetentionStatus
        if retainOriginalAudioAfterTranscription {
          retentionStatusBeforeSaving = .kept
        } else if whisperProcessingCompletedSuccessfully {
          // 첫 저장 시점에는 실제 파일이 아직 있으므로 상태도 kept가 정확하다.
          // 삭제가 성공한 뒤 deletedAfterWhisper로 바꾸고 한 번 더 원자 저장한다.
          retentionStatusBeforeSaving = .kept
        } else {
          retentionStatusBeforeSaving = .retainedForRecovery
        }
        store.setAudioRetentionStatus(retentionStatusBeforeSaving)
      }

      guard let dir = try SessionStore.save(store) else {
        logError("저장 대상 폴더를 정하지 못했습니다")
        return nil
      }

      if !retainOriginalAudioAfterTranscription,
         whisperProcessingCompletedSuccessfully,
         completedAudioArchive != nil {
        do {
          let deletedAudioFileCount = try removeArchivedAudioFiles(in: dir)
          store.setAudioRetentionStatus(.deletedAfterWhisper)
          _ = try SessionStore.save(store)
          log("Whisper 처리 완료 후 원본 소리 \(deletedAudioFileCount)개를 삭제했습니다.")
        } catch {
          // 일부 삭제 뒤 오류가 나도 transcript와 session.json은 이미 저장돼 있다.
          // 실패 상태를 다시 저장해 설정 화면에서 조치가 필요함을 숨기지 않는다.
          store.setAudioRetentionStatus(.deletionFailed)
          do {
            _ = try SessionStore.save(store)
          } catch {
            logError("원본 소리 삭제 실패 상태를 저장하지 못했습니다: \(error)")
          }
          logWarn("원본 소리를 모두 삭제하지 못해 남은 파일을 보존합니다: \(error.localizedDescription)")
          live.broadcast(event: "status", payload: [
            "message": "원본 소리 자동 삭제를 마치지 못했습니다. 설정에서 저장 상태를 확인해 주세요.",
            "level": "warn",
          ])
        }
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

  /// 세션 폴더 안에서 AudioArchive가 만든 이름의 WAV만 지운다.
  ///
  /// 사용자가 선택한 상위 저장 폴더 전체를 대상으로 삼거나 `*.wav` 같은 넓은 패턴을
  /// 쓰면 교안 음원까지 지울 수 있다. AudioArchive가 이미 파싱한 목록을 다시 경로와
  /// 이름으로 검증하고, 하나라도 범위를 벗어나면 즉시 멈춘다.
  private func removeArchivedAudioFiles(in sessionDirectory: URL) throws -> Int {
    let canonicalSessionDirectory = sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let archivedAudioClips = AudioArchive.clips(in: sessionDirectory)
    var deletedAudioFileCount = 0

    for audioClip in archivedAudioClips {
      let audioFileURL = audioClip.url.standardizedFileURL
      let canonicalParentDirectory = audioFileURL.deletingLastPathComponent()
        .resolvingSymlinksInPath()
      let audioFileName = audioFileURL.lastPathComponent
      let numericOffset = audioFileName
        .dropFirst("audio_".count)
        .dropLast(".wav".count)
      let hasNumericTimelineOffset = !numericOffset.isEmpty
        && numericOffset.allSatisfy { $0.wholeNumberValue != nil }

      guard canonicalParentDirectory == canonicalSessionDirectory,
            audioFileName.hasPrefix("audio_"),
            audioFileName.hasSuffix(".wav"),
            hasNumericTimelineOffset
      else {
        throw NSError(
          domain: "ZoomCaption.AudioRetention",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey:
            "세션 폴더 밖이거나 예상하지 않은 이름의 오디오 파일은 삭제하지 않았습니다."])
      }

      try FileManager.default.removeItem(at: audioFileURL)
      deletedAudioFileCount += 1
    }
    return deletedAudioFileCount
  }

  // MARK: - 문맥 다듬기 (자기 일관성 교정 — 미리보기)

  /// Whisper 기록을 원안으로 두고, 강의 전체 문맥으로 표기 불일치를 찾는다.
  /// **지금은 미리보기 단계다** — 결과를 곧바로 반영하지 않고 제안 목록만 화면에
  /// 띄운다(원문은 안 건드린다). segID 없이 "이 표기 → 저 표기" 규칙만 모델에게
  /// 받고, 실제로 원문 어디에 있는지·근거가 있는지는 여기서 검증만 해서 같이
  /// 보여준다 — 사람이 보고 신뢰할 만한지 가늠하라는 뜻이지, 자동 적용 여부를
  /// 정하는 게 아니다.
  func suggestPolish() async {
    let text = store.plainText(includeTimestamps: false)
    guard !text.isEmpty else {
      live.broadcast(event: "polishDone", payload: ["ok": false, "error": "녹취 내용이 없습니다."])
      return
    }
    live.broadcast(event: "polishProgress", payload: ["message": "모델을 준비하는 중…"], durable: false)
    // 서버가 안 떠 있어도 디스크에 모델이 있으면 골라 둔다(Summarizer.currentEngine
    // 과 같은 패턴) — 아래 ensureServer() 가 실제로 띄운다.
    let model: String
    if let installed = await OllamaClient.installedModels(),
       let m = OllamaClient.pickModel(from: installed) {
      model = m
    } else if OllamaClient.binaryPath != nil,
              let m = OllamaClient.pickModel(from: OllamaClient.installedModelsOffline()) {
      model = m
    } else {
      live.broadcast(event: "polishDone", payload: [
        "ok": false, "error": "쓸 수 있는 Ollama 모델이 없습니다. `ollama pull qwen3:8b` 로 내려받으세요."])
      return
    }
    guard await OllamaClient.ensureServer() else {
      live.broadcast(event: "polishDone", payload: ["ok": false, "error": "Ollama 서버를 띄우지 못했습니다."])
      return
    }
    live.broadcast(event: "polishProgress", payload: ["message": "강의 전체를 검토하는 중…"], durable: false)
    let glossary = DomainKnowledge.glossary(store.domainTerms)
    do {
      let suggestions = try await OllamaClient.suggestCorrections(
        transcript: text, title: store.title, glossary: glossary, model: model)

      // 검증(적용은 안 함) — before 가 실제 원문에 있는지, after 가 교안/녹취
      // 다른 곳에 근거가 있는지만 표시한다. 모델이 규칙을 어겼는지 한눈에 보임.
      let allText = store.whisperSegments.map(\.text).joined(separator: "\n")
      let glossarySet = Set(store.domainTerms.map { $0.replacingOccurrences(of: " ", with: "").lowercased() })
      let annotated = suggestions.map { s -> (s: OllamaClient.CorrectionSuggestion, beforeExists: Bool, afterGrounded: Bool) in
        let beforeExists = allText.contains(s.before)
        let normalizedAfter = s.after.replacingOccurrences(of: " ", with: "").lowercased()
        let afterGrounded = glossarySet.contains(normalizedAfter) || allText.contains(s.after)
        return (s, beforeExists, afterGrounded)
      }
      log("문맥 다듬기 미리보기 — 제안 \(suggestions.count)건 "
        + "(원문에 있음 \(annotated.filter(\.beforeExists).count)건, "
        + "근거 있음 \(annotated.filter(\.afterGrounded).count)건)")

      let payload = annotated.map { a -> [String: Any] in
        ["before": a.s.before, "after": a.s.after, "reason": a.s.reason,
         "beforeExists": a.beforeExists, "afterGrounded": a.afterGrounded]
      }
      live.broadcast(event: "polishDone", payload: ["ok": true, "model": model, "corrections": payload])
    } catch {
      live.broadcast(event: "polishDone", payload: ["ok": false, "error": error.localizedDescription])
    }
  }

  // MARK: - 요약

  /// 로컬 Qwen 경로와 온라인 붙여넣기 경로가 같은 뒷정리를 하도록 한 곳에 모은다.
  /// 여기서 autosave나 SSE 브로드캐스트를 빠뜨리면 이미 열려 있는 다른 브라우저 탭이
  /// 새 요약을 영영 못 본다.
  func applySummary(_ markdown: String,
                    lastSummarizedAt: Double?,
                    engineNote: String,
                    from: Double?) {
    store.summary = markdown
    store.lastSummarizedAt = lastSummarizedAt
    store.summaryEngineNote = engineNote
    autosave()
    live.broadcast(event: "summaryDone", payload: [
      "ok": true,
      "markdown": markdown,
      "lastSummarizedAt": lastSummarizedAt ?? 0,
      "from": from ?? 0,
      "engineNote": engineNote,
    ])
  }

  func runSummary(units: [LectureUnit], from: Double?, job: SummaryJob) async {
    defer {
      // 해제 지점은 여기 하나뿐이다. 예전에는 defer·성공·실패 세 갈래가 각각
      // `summaryGeneration == generation`을 걸고 플래그를 껐는데, generation이 진행 중에
      // 바뀌면 어느 쪽도 끄지 못해 앱이 "요약 중"에 영구히 갇혔다. 조건 없이 자기
      // 작업만 비우면 그 상태가 성립할 수 없다.
      stateLock.withLock {
        if activeSummaryJob === job { activeSummaryJob = nil }
      }
    }
    // 범위를 자르기 전에 Store가 붙인 전체 기준 unit id를 그대로 모델과 Renderer까지
    // 운반해야 부분 요약의 3강이 다시 1강으로 바뀌지 않는다. 세그먼트 평탄화는 기존
    // 로그와 마지막 끝 시각 계산에만 쓰고, 구간 재생성에는 쓰지 않는다.
    let segments = units.flatMap(\.segments)
    let textCount = segments.reduce(0) { $0 + $1.text.count }
    log("요약 시작 — 범위 \(from.map { TranscriptStore.clock($0) + " 이후" } ?? "전체"), "
      + "\(segments.count)줄 / \(textCount)자, 교안 용어 \(store.domainTerms.count)개")
    let glossary = DomainKnowledge.glossary(store.domainTerms)
    do {
      // Summarizer가 내부에서 선택하는 것과 같은 선택기를 바로 앞에서 읽어, 반환형을
      // 넓히지 않고도 실제 로컬 모델 이름을 저장 출처에 남긴다.
      let engineNote = await Summarizer.currentEngine().label
      let result = try await Summarizer.summarize(
        units: units, title: store.title, glossary: glossary) { done, total in
          // 새로고침한 브라우저가 복원할 수 있도록 작업에도 남기고, 열려 있는 탭에는
          // 그대로 흘려 보낸다.
          job.recordProgress(completed: done, total: total)
          self.live.broadcast(event: "summaryProgress",
                              payload: ["done": done, "total": total], durable: false)
        }

      // 이 작업이 여전히 현재 작업이고, 시작할 때와 같은 세션인지 둘 다 본다. 세션이
      // 바뀌었다면 결과를 쓰는 순간 autosave가 **다른 수업 폴더**에 이 요약을 적어 넣는다.
      let shouldApply = stateLock.withLock { activeSummaryJob === job }
        && job.sessionDir == store.sessionDir
      guard shouldApply else {
        logWarn("요약 결과를 저장하지 않았습니다 — 그 사이 취소되었거나 세션이 바뀌었습니다.")
        return
      }
      let lastSummarizedAt = segments.map(\.end).max()
      applySummary(result, lastSummarizedAt: lastSummarizedAt,
                   engineNote: engineNote, from: from)
      log("요약 완료 — 마지막 지점 \(lastSummarizedAt.map(TranscriptStore.clock) ?? "-")")
    } catch {
      // 취소는 실패가 아니다. 그런데 모델 호출이 URLSession 위에 있어서, 취소가
      // CancellationError가 아니라 URLError.cancelled로 올라온다. 한 형태만 잡으면
      // 사용자가 직접 누른 취소가 "요약 실패: cancelled" 오류 배너로 보인다.
      let wasCancelled = error is CancellationError
        || (error as? URLError)?.code == .cancelled
        || Task.isCancelled
      if wasCancelled {
        log("요약 취소됨 — 진행 중이던 로컬 요약을 중단했습니다.")
        live.broadcast(event: "summaryDone", payload: [
          "ok": false,
          "cancelled": true,
          "error": "요약을 취소했습니다.",
        ])
        return
      }
      guard stateLock.withLock({ activeSummaryJob === job }) else { return }
      logError("요약 실패: \(error.localizedDescription)")
      live.broadcast(event: "summaryDone", payload: [
        "ok": false,
        "error": error.localizedDescription,
      ])
    }
  }
}

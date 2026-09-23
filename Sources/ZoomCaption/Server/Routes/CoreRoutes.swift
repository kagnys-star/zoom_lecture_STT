import Foundation
import AVFoundation
import AppKit

/// 화면 자체와 상태·로그·진단. 어느 주제에도 안 붙는 기본 경로들이다.

/// 브라우저 오류가 연쇄적으로 발생해도 파일 로그를 초당 수백 줄로 밀어내지 않도록
/// 프로세스 전체에서 짧은 고정 창을 공유한다. localhost 한 사용자 앱이라 IP별 분리는
/// 의미가 없고, 초과분은 진단 자체가 장애를 키우지 않게 조용히 버린다.
private final class ClientLogRateLimiter: @unchecked Sendable {
  private let lock = NSLock()
  private var windowStartedAt = ProcessInfo.processInfo.systemUptime
  private var acceptedCount = 0

  func shouldAccept() -> Bool {
    lock.withLock {
      let currentUptime = ProcessInfo.processInfo.systemUptime
      if currentUptime - windowStartedAt >= 1 {
        windowStartedAt = currentUptime
        acceptedCount = 0
      }
      guard acceptedCount < 10 else { return false }
      acceptedCount += 1
      return true
    }
  }
}

private let clientLogRateLimiter = ClientLogRateLimiter()

extension ZoomCaptionApp {
  func coreRoutes(_ req: HTTPRequest) async -> Route? {
    switch (req.method, req.path) {
    case ("GET", "/"):
      return .response(.html(WebUI.page(isAdministratorMode: options.admin)))

    case ("GET", "/events"):
      return .eventStream

    // setup.sh 가 내려받아 둔 자막 글자체. 없으면 404 → CSS가 시스템 폰트로 조용히 넘어간다.
    case ("GET", "/fonts/pretendard.woff2"):
      guard let path = FontAssets.pretendardVariablePath,
            let data = try? Data(contentsOf: path) else {
        return .response(.notFound)
      }
      return .response(HTTPResponse(
        contentType: "font/woff2",
        body: data,
        extraHeaders: ["Cache-Control": "public, max-age=604800, immutable"]
      ))

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

    case ("POST", "/api/clientLog"):
      guard clientLogRateLimiter.shouldAccept() else {
        return .response(.json(["ok": true]))
      }
      let request = req.json(ClientLogRequest.self)
      // 브라우저는 프롬프트·요약·전사 본문을 절대 보내지 않고, API 지원 여부와
      // 길이·오류 이름/메시지 같은 진단 메타데이터만 보낸다. 줄바꿈도 지워 한 요청이
      // 여러 서버 로그처럼 위장하지 못하게 하고, 500자로 잘라 로그 용량을 제한한다.
      let message = String((request?.message ?? "").prefix(500))
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
      switch request?.level {
      case "warn": Logger.shared.log(.warn, "[client] \(message)")
      case "error": Logger.shared.log(.error, "[client] \(message)")
      case "info": Logger.shared.log(.info, "[client] \(message)")
      default:
        // 알 수 없는 level을 그대로 파일 형식에 넣지 않고 info로 강등한다.
        Logger.shared.log(.info, "[client] \(message)")
      }
      return .response(.json(["ok": true]))

    case ("POST", "/api/logs/reveal"):
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Logger.shared.directory.path)
      return .response(.json(["ok": true]))


    case ("GET", "/api/diag"):
      return .response(.json(diagJSON()))


    default:
      return nil
    }
  }
}

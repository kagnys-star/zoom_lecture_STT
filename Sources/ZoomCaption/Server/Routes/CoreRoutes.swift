import Foundation
import AVFoundation
import AppKit

/// 화면 자체와 상태·로그·진단. 어느 주제에도 안 붙는 기본 경로들이다.

extension ZoomCaptionApp {
  func coreRoutes(_ req: HTTPRequest) async -> Route? {
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


    case ("GET", "/api/diag"):
      return .response(.json(diagJSON()))


    default:
      return nil
    }
  }
}

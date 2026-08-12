import Foundation

// MARK: - 실행 설정

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

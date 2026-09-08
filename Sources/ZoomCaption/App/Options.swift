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
    var dirGiven = false
    while i < args.count {
      switch args[i] {
      case "--port": if i + 1 < args.count, let p = UInt16(args[i + 1]) { o.port = p; i += 1 }
      case "--locale": if i + 1 < args.count { o.localeID = args[i + 1]; i += 1 }
      case "--dir":
        if i + 1 < args.count { o.baseDir = URL(fileURLWithPath: args[i + 1]); dirGiven = true; i += 1 }
      case "--no-open": o.openBrowser = false
      case "--admin": o.admin = true
      default: break
      }
      i += 1
    }
    if ProcessInfo.processInfo.environment["ZOOMCAPTION_ADMIN"] == "1" { o.admin = true }
    // --dir 는 테스트 격리용이다. 관리자 모드 없이 조용히 통과시키면, 나중에 --admin
    // 을 빠뜨린 실행이 실사용 저장 위치(StorageLocation)가 아니라 --dir 값을 그대로
    // 따르는 줄 알고 있다가 실제로는 무시되는 식의 사고를 부를 수 있어 아예 막는다.
    if dirGiven, !o.admin {
      logError("--dir 는 --admin 과 함께만 쓸 수 있습니다 (실사용 저장 위치는 앱 설정에서 바꿉니다).")
      exit(1)
    }
    return o
  }
}

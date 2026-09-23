import Foundation

/// 자막 글자체(Pretendard) 파일 위치.
///
/// 시스템 폰트에만 기대면 macOS/Windows 브라우저마다 자막이 다르게 보이고,
/// Apple SD Gothic Neo 는 macOS 라이선스라 앱에 직접 담을 수 없다. 그래서
/// `setup.sh` 가 최초 1회 내려받아 여기 둔다 — 없으면 라우트가 404 를 주고
/// CSS 폴백 스택(시스템 폰트)으로 조용히 넘어간다. 필수 기능이 아니다.
enum FontAssets {
  static var pretendardVariablePath: URL? {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/ZoomCaption/fonts/PretendardVariable.woff2", isDirectory: false)
    return FileManager.default.fileExists(atPath: path.path) ? path : nil
  }
}

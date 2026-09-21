import Foundation

/// 브라우저에 내려보내는 한 장짜리 화면. 이 파일은 **붙이기만** 한다.
///
/// ```
/// WebUI+Style.swift    화면 스타일        (CSS)
/// WebUI+Markup.swift   화면 뼈대          (HTML)
/// WebUI+Script.swift   화면 동작          (JS)
/// ```
///
/// **왜 나눴나.** 셋이 한 파일에 2,056줄로 엉켜 있었다. 색 하나를 고치려 해도
/// 1,400줄짜리 JS 를 헤집고 지나가야 했고, 실제로 이 파일에서 지운 버튼의
/// 이벤트 처리기를 안 지워 스크립트가 통째로 멈춘 적이 있다
/// (`Cannot set properties of null` — 그 줄 아래가 전부 죽었다).
///
/// **왜 리소스 파일이 아니라 문자열인가.** 실행 파일 하나만 있으면 돌아가는 게
/// 이 앱의 장점이라 그대로 두었다. 리소스 번들로 빼면 `build.sh` 가 `.app` 안에
/// 따로 복사해야 하고 경로 처리가 늘어난다.
///
/// **원시 문자열(`#"""`)인 이유.** JS 의 `${...}` 템플릿 리터럴과 정규식 역슬래시가
/// 그대로 통과해야 한다. 그래서 값을 끼워 넣을 때는 `\#(...)` 를 쓴다.
enum WebUI {
  /// 실행 역할을 HTML의 명시적인 상태로 내려보낸다.
  ///
  /// 관리자 여부를 브라우저가 임의로 결정하게 두면 개발자 도구에서 클래스 하나만
  /// 바꿔 실험 도구를 운영 화면처럼 보이게 할 수 있다. 서버가 시작 옵션을 기준으로
  /// body 클래스와 녹음 버튼 문구를 확정하고, 실제 API 권한은 라우트에서 다시 검사한다.
  static func page(isAdministratorMode: Bool) -> String {
    let bodyClass = isAdministratorMode ? "administrator-mode" : "user-mode"
    let pageTitle = isAdministratorMode ? "ZoomCaption 관리자" : "ZoomCaption"
    let recordingButtonLabel = isAdministratorMode ? "테스트 캡처 시작" : "녹음 시작"

    return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>\#(pageTitle)</title>
<style>
\#(style)
</style>
</head>
<body class="\#(bodyClass)">
\#(markup.replacingOccurrences(of: "__RECORD_BUTTON_LABEL__", with: recordingButtonLabel))
<script>
\#(script)
</script>
</body>
</html>
"""#
  }
}

import Foundation
import AppKit

// MARK: - 진입점
//
// 이 파일은 **실행을 시작하는 것 말고는 아무 일도 하지 않는다.**
// SwiftPM 실행 대상은 `main.swift` 안의 최상위 코드부터 돌기 시작한다.

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.contains("--summary-check") {
  runSummaryPipelineChecks()
}

if rawArgs.contains("--webui-check") {
  runWebUIContractChecks()
}

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

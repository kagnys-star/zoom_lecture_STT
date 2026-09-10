import Foundation

enum LogLevel: String, Sendable {
  case debug = "DEBUG"
  case info  = "INFO"
  case warn  = "WARN"
  case error = "ERROR"
}

/// 파일 로거.
///
/// 이 앱은 LSUIElement 라 `open` 으로 띄우면 stderr 가 어디에도 남지 않는다.
/// 시작에 실패하면 아무 흔적 없이 사라지므로 파일 로그가 사실상 유일한 단서다.
/// 위치는 macOS 표준인 ~/Library/Logs/ZoomCaption/ 이라 Console.app 에서도 보인다.
final class Logger: @unchecked Sendable {
  static let shared = Logger()

  /// 보관 기간. 수업은 주 1~3회라 2주면 2~6회분이 남는다.
  /// 간헐적 문제("가끔 안 켜짐")의 재현 패턴을 보기에 충분하면서,
  /// 로그가 계속 쌓여 신경 쓰이는 일은 없는 선.
  static let retentionDays = 14
  /// 그래도 무언가 폭주해 디스크를 채우는 일은 막는다.
  static let maxTotalBytes = 20 << 20   // 20MB

  let directory: URL
  private let queue = DispatchQueue(label: "zoomcaption.logger")
  private var handle: FileHandle?
  private var currentDay = ""
  /// 관리자 시험과 실사용 앱은 서로 다른 프로세스지만 같은 날짜에 동시에 실행될 수
  /// 있다. 날짜만 파일명에 넣으면 각 프로세스의 독립적인 FileHandle 오프셋이 충돌해
  /// 두 로그가 한 줄에 붙거나 덮어써진다. 역할과 PID를 고정해 프로세스마다 한 파일만
  /// 쓰게 하면 별도의 프로세스 간 잠금 없이도 기록 경계가 보존된다.
  private let processLogIdentity: String
  /// prune이 현재 열어 둔 파일을 지우지 않도록 실제 파일명을 기억한다. 예전의 날짜
  /// 기반 비교는 PID·역할 접미사가 붙은 뒤 현재 파일을 알아보지 못한다.
  private var currentLogFileName = ""

  private let ringLock = NSLock()
  private var ring: [String] = []
  private let ringCapacity = 800

  private lazy var stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()
  private lazy var day: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  private init() {
    let processInfo = ProcessInfo.processInfo
    let administratorModeWasRequested = processInfo.arguments.contains("--admin")
      || processInfo.environment["ZOOMCAPTION_ADMIN"] == "1"
    let processRole = administratorModeWasRequested ? "admin" : "live"
    processLogIdentity = "\(processRole)-pid-\(processInfo.processIdentifier)"
    directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/ZoomCaption", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 첫 log()가 날짜와 현재 프로세스의 파일명을 확정한 뒤 rollIfNeeded()에서
    // 정리한다. 여기서 먼저 prune하면 어떤 파일이 현재 실행 중인 프로세스의 것인지
    // 아직 모르므로, 용량 제한에 걸린 날 관리자 시험이 실사용 로그를 지울 수 있다.
  }

  // MARK: - 쓰기

  func log(_ level: LogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
    let where_ = "\(file.split(separator: "/").last.map(String.init) ?? file):\(line)"
    let now = Date()
    let text = "\(stamp.string(from: now)) [\(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))] \(where_) \(message)"

    ringLock.lock()
    ring.append(text)
    if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
    ringLock.unlock()

    // 터미널에서 직접 실행했을 때도 보이도록 유지한다.
    FileHandle.standardError.write(Data("[ZoomCaption] \(message)\n".utf8))

    queue.async { [weak self] in
      guard let self else { return }
      self.rollIfNeeded(now)
      self.handle?.write(Data((text + "\n").utf8))
    }
  }

  /// 프로세스를 끝내기 직전에 부른다. 로그 쓰기는 큐에 비동기로 실려 있어서,
  /// 여기서 한 번 비워 주지 않으면 종료 과정의 마지막 줄들이 파일에 남지 않는다.
  func flush() {
    queue.sync { self.handle?.synchronizeFile() }
  }

  private func rollIfNeeded(_ now: Date) {
    let today = day.string(from: now)
    guard today != currentDay || handle == nil else { return }

    try? handle?.close()
    handle = nil
    currentDay = today

    let logFileName = "zoomcaption-\(today)-\(processLogIdentity).log"
    let url = directory.appendingPathComponent(logFileName)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    currentLogFileName = logFileName
    prune()
  }

  // MARK: - 보관 정책

  /// 기간이 지난 파일을 지우고, 그래도 크면 오래된 것부터 지운다.
  private func prune() {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
    else { return }

    let logs = files.filter { $0.pathExtension == "log" }
    let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)

    var survivors: [(url: URL, date: Date, size: Int)] = []
    for url in logs {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      let modified = values?.contentModificationDate ?? .distantPast
      let size = values?.fileSize ?? 0
      // 오늘 날짜의 파일은 다른 live/admin 프로세스가 지금 쓰는 중일 수 있다.
      // FileHandle을 열었는지는 프로세스 밖에서 안전하게 판별할 수 없으므로 현재
      // 파일뿐 아니라 오늘 파일 전체를 보존하고, 지난 날짜 파일만 정리 대상으로 삼는다.
      if modified < cutoff, !isPotentiallyActiveLog(url.lastPathComponent) {
        try? fm.removeItem(at: url)
      } else {
        survivors.append((url, modified, size))
      }
    }

    var total = survivors.reduce(0) { $0 + $1.size }
    guard total > Self.maxTotalBytes else { return }
    for entry in survivors.sorted(by: { $0.date < $1.date }) {
      guard total > Self.maxTotalBytes else { break }
      guard !isPotentiallyActiveLog(entry.url.lastPathComponent) else { continue }
      try? fm.removeItem(at: entry.url)
      total -= entry.size
    }
  }

  /// 날짜만 쓰던 예전 파일과 역할·PID가 붙는 새 파일을 모두 보호한다. 같은 날 열린
  /// 다른 프로세스 로그까지 보존해야 독립 관리자 시험이 실사용 진단 기록을 훼손하지 않는다.
  private func isPotentiallyActiveLog(_ fileName: String) -> Bool {
    guard !currentDay.isEmpty else { return true }
    return fileName == currentLogFileName
      || fileName == "zoomcaption-\(currentDay).log"
      || fileName.hasPrefix("zoomcaption-\(currentDay)-")
  }

  // MARK: - 읽기

  /// 최근 로그 (UI 표시용)
  func recent(limit: Int = 300) -> [String] {
    ringLock.withLock { Array(ring.suffix(limit)) }
  }

  /// 보관 중인 로그 파일 목록
  func files() -> [(name: String, size: Int, modified: Date)] {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
    else { return [] }
    return urls.filter { $0.pathExtension == "log" }.map { url in
      let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      return (url.lastPathComponent, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
    }.sorted { $0.modified > $1.modified }
  }
}

// MARK: - 전역 단축 함수

func log(_ message: String, file: String = #fileID, line: Int = #line) {
  Logger.shared.log(.info, message, file: file, line: line)
}
func logWarn(_ message: String, file: String = #fileID, line: Int = #line) {
  Logger.shared.log(.warn, message, file: file, line: line)
}
func logError(_ message: String, file: String = #fileID, line: Int = #line) {
  Logger.shared.log(.error, message, file: file, line: line)
}
func logDebug(_ message: String, file: String = #fileID, line: Int = #line) {
  Logger.shared.log(.debug, message, file: file, line: line)
}

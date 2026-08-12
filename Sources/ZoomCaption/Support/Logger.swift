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
    directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/ZoomCaption", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    queue.async { [weak self] in self?.prune() }
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
    queue.sync { try? self.handle?.synchronizeFile() }
  }

  private func rollIfNeeded(_ now: Date) {
    let today = day.string(from: now)
    guard today != currentDay || handle == nil else { return }

    try? handle?.close()
    handle = nil
    currentDay = today

    let url = directory.appendingPathComponent("zoomcaption-\(today).log")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    try? handle?.seekToEnd()
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
      // 지금 쓰고 있는 파일은 건드리지 않는다.
      if modified < cutoff, url.lastPathComponent != "zoomcaption-\(currentDay).log" {
        try? fm.removeItem(at: url)
      } else {
        survivors.append((url, modified, size))
      }
    }

    var total = survivors.reduce(0) { $0 + $1.size }
    guard total > Self.maxTotalBytes else { return }
    for entry in survivors.sorted(by: { $0.date < $1.date }) {
      guard total > Self.maxTotalBytes else { break }
      guard entry.url.lastPathComponent != "zoomcaption-\(currentDay).log" else { continue }
      try? fm.removeItem(at: entry.url)
      total -= entry.size
    }
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

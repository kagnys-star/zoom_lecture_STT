import Foundation
import AppKit

/// 세션 폴더 하나 = 수업 하나.
/// 안에 session.json(원본) / transcript.md / transcript.srt / 교안 PDF 가 들어간다.
enum SessionStore {
  static let jsonName = "session.json"
  static let mdName = "transcript.md"
  static let srtName = "transcript.srt"
  /// 실시간 전사기 기록. transcript.md 가 Whisper 로 채워질 때 짝으로 남는다.
  static let liveName = "transcript_live.md"

  private static var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    return e
  }
  private static var decoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }

  /// 파일명으로 못 쓰는 문자를 정리한다.
  static func sanitize(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
    let cleaned = name.components(separatedBy: bad).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "수업" : String(cleaned.prefix(80))
  }

  /// base 안에 이번 수업용 폴더를 새로 만든다.
  /// base 는 "어디에 만들지"(상위 폴더), name 은 "폴더 이름"이다.
  /// 같은 이름이 있으면 (2), (3) 을 붙여 절대 덮어쓰지 않는다.
  static func createDir(base: URL, name: String?, title: String) throws -> URL {
    let fm = FileManager.default
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HHmm"
    let stamp = df.string(from: Date())
    let leaf: String
    if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
      leaf = sanitize(name)
    } else {
      leaf = "\(stamp)_\(sanitize(title))"
    }

    var url = base.appendingPathComponent(leaf, isDirectory: true)
    var n = 2
    while fm.fileExists(atPath: url.path) {
      url = base.appendingPathComponent("\(leaf) (\(n))", isDirectory: true)
      n += 1
    }
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  static func save(_ store: TranscriptStore) throws -> URL? {
    guard let dir = store.sessionDir else { return nil }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let snapshot = store.snapshot()
    try encoder.encode(snapshot).write(to: dir.appendingPathComponent(jsonName), options: .atomic)
    try store.markdown().write(to: dir.appendingPathComponent(mdName), atomically: true, encoding: .utf8)
    try store.srt().write(to: dir.appendingPathComponent(srtName), atomically: true, encoding: .utf8)
    // 두 전사 결과를 모두 남긴다. 위 transcript.md 는 좋은 쪽(Whisper)을 쓰지만,
    // 실시간 기록도 지우지 않는다 — 서로 실수하는 자리가 달라서 대조에 쓸모가 있다.
    if store.hasWhisper {
      try? store.liveMarkdown().write(to: dir.appendingPathComponent(liveName),
                                      atomically: true, encoding: .utf8)
    }
    return dir
  }

  static func load(dir: URL) throws -> SessionFile {
    let data = try Data(contentsOf: dir.appendingPathComponent(jsonName))
    return try decoder.decode(SessionFile.self, from: data)
  }

  /// base 아래에서 session.json 을 가진 폴더를 최근 순으로 나열한다.
  static func list(base: URL) -> [[String: Any]] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }

    var out: [[String: Any]] = []
    for entry in entries {
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
      guard let file = try? load(dir: entry) else { continue }
      out.append([
        "path": entry.path,
        "folder": entry.lastPathComponent,
        "title": file.title,
        "segments": file.segments.count,
        "duration": file.duration,
        "updatedAt": ISO8601DateFormatter().string(from: file.updatedAt),
        "hasSummary": file.summary?.isEmpty == false,
        "domainSource": file.domainSource ?? "",
      ])
    }
    return out.sorted { ($0["updatedAt"] as? String ?? "") > ($1["updatedAt"] as? String ?? "") }
  }

  /// 폴더 선택 다이얼로그.
  ///
  /// NSOpenPanel 은 이 앱이 LSUIElement(백그라운드) 라서 창이 뜨지 않고 즉시 실패했다.
  /// osascript 의 `choose folder` 는 별도 프로세스가 자기 창을 띄우므로 안정적으로 동작하고,
  /// 그 대화상자에 "새로운 폴더" 버튼도 들어 있다.
  static func pickFolder(startingAt: URL?) -> String? {
    let start = startingAt.map { "default location POSIX file \"\($0.path)\" " } ?? ""
    let script = """
      POSIX path of (choose folder with prompt "수업 기록을 저장할 폴더를 고르세요" \(start))
      """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice

    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    // 사용자가 취소하면 osascript 가 -128 로 끝난다.
    guard process.terminationStatus == 0,
          let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty
    else { return nil }
    // choose folder 는 끝에 / 를 붙여 준다.
    return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
  }
}

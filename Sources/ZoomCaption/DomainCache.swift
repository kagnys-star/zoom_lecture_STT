import Foundation
import CryptoKit

/// 교안 분석 결과 캐시.
///
/// 363쪽 교안 하나를 처리하는 데 mecab 추출 약 9초 + 로컬 모델 정제 약 18초가 든다.
/// 같은 파일을 다시 올리는 일이 잦은데(이어 적기, 새 세션, 앱 재시작)
/// 그때마다 30초를 다시 쓸 이유가 없다. 파일 내용 해시로 붙잡아 둔다.
enum DomainCache {

  /// 추출 규칙이 바뀌면 예전 캐시는 버려야 한다. 파이프라인을 고칠 때 올린다.
  private static let version = 3

  struct Entry: Codable {
    var pages: Int
    var characters: Int
    var terms: [String]
    var looksScanned: Bool
    var analyzer: String
    var droppedBoilerplate: [String]
    /// "규칙" 또는 "규칙 + qwen3:8b"
    var refinedBy: String
    var sourceName: String
    var cachedAt: Date
    var version: Int
  }

  static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/ZoomCaption/domain", isDirectory: true)
  }

  /// 파일 내용 해시. 이름이 달라도 같은 교안이면 같은 키가 된다.
  static func key(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func load(key: String) -> Entry? {
    let url = directory.appendingPathComponent("\(key).json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601   // save() 의 인코딩 방식과 반드시 같아야 한다
    guard let entry = try? decoder.decode(Entry.self, from: data) else {
      // 읽을 수 없는 캐시는 조용히 넘어가지 말고 남긴다. 안 그러면 매번 재분석하면서도 이유를 모른다.
      logWarn("교안 캐시를 읽지 못해 다시 분석합니다: \(url.lastPathComponent)")
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    guard entry.version == version else {
      // 규칙이 바뀐 뒤의 낡은 캐시. 지우고 새로 분석하게 둔다.
      try? FileManager.default.removeItem(at: url)
      log("교안 캐시가 낡아 버립니다 (v\(entry.version) → v\(version))")
      return nil
    }
    // 파일을 열어본 시각을 갱신해 두면 오래된 것부터 정리하기 쉽다.
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    return entry
  }

  static func save(key: String, _ entry: Entry) {
    var entry = entry
    entry.version = version
    entry.cachedAt = Date()
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(entry) else { return }
    try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    prune()
  }

  /// 캐시 항목은 파일당 수 KB 라 용량이 문제될 일은 없지만, 무한정 쌓이게 두지는 않는다.
  private static let maxEntries = 50

  private static func prune() {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let files = urls.filter { $0.pathExtension == "json" }
    guard files.count > maxEntries else { return }
    let sorted = files.sorted {
      let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return a < b
    }
    for url in sorted.prefix(files.count - maxEntries) { try? fm.removeItem(at: url) }
  }

  /// 진단용 요약
  static func stats() -> (count: Int, bytes: Int64) {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
    else { return (0, 0) }
    let files = urls.filter { $0.pathExtension == "json" }
    let bytes = files.reduce(Int64(0)) {
      $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return (files.count, bytes)
  }

  static func clear() {
    try? FileManager.default.removeItem(at: directory)
    log("교안 캐시를 비웠습니다.")
  }

  /// `--decache` 로 캐시만 지우고 끝낼 때 쓴다.
  static var decacheRequested: Bool {
    CommandLine.arguments.contains("--decache")
  }
}

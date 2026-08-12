import Foundation

/// 사람이 소리를 듣고 판정한 표본 하나.
///
/// 왜 "구간 받아쓰기" 가 아니라 이 모양인가 —
/// 5분 구간을 통째로 받아쓰면 800자를 쳐야 한다. 그래서 아무도 안 한다.
/// 대신 **두 전사기가 갈린 자리만** 골라 물으면, 대부분은 둘 중 하나가 맞아서
/// 한 번의 선택으로 끝난다. 같은 시간에 표본이 수십 배 모인다.
///
/// 한계도 분명하다 — 둘이 **같은 방식으로 틀린 자리**는 이 표본에 안 잡힌다.
/// 그래서 구간 받아쓰기(Reference)도 남겨 둔다. 둘은 서로를 대체하지 않는다.
struct GoldSample: Codable, Sendable, Equatable {
  var start: Double
  var end: Double
  var kind: String          // script | missing | differ
  var live: String          // 실시간 쪽 표기
  var whisper: String       // Whisper 쪽 표기
  /// 실제로 들린 내용. verdict 가 live/whisper 면 그쪽 값과 같다.
  var truth: String
  /// live | whisper | both — both 는 둘 다 틀려서 truth 를 직접 적은 경우
  var verdict: String
  var at: Date

  /// 표본 형식. **1(또는 없음) = 못 쓰는 옛 표본.**
  ///
  /// 1 번은 화면에 원문(`hash map이나 hash set`)을 보여주고 저장은 정규화된 글자
  /// (`hashmap이나hashset`)를 했다. 사람이 본 것과 기록된 것이 달라서
  /// 띄어쓰기·대소문자가 지워진 채 정답으로 박혔다. 채점에 쓰면 멀쩡한 전사도
  /// 틀렸다고 나온다. 지우지는 않되 **집계에서 뺀다.**
  ///
  /// **반드시 Optional 이어야 한다.** `var schema: Int = 1` 처럼 기본값만 주면
  /// Swift 가 만들어 주는 디코더는 키가 없을 때 기본값을 쓰지 않고 **통째로 실패한다.**
  /// 그러면 옛 파일이 빈 묶음으로 읽히고, 다음 저장이 사용자의 표본을 덮어쓴다.
  /// (실제로 그렇게 표본 5개를 날렸다.)
  var schema: Int?
  var formatVersion: Int { schema ?? 1 }

  /// 본문에서 바로 고친 자리라면 어느 줄 어디인지. 옛 표본에는 없다.
  var segID: Int?
  var rangeStart: Int?
  var rangeEnd: Int?

  /// 같은 지점을 다시 판정하면 덮어쓰기 위한 키.
  /// 시각은 정렬 결과가 조금씩 달라질 수 있어 0.1초로 뭉갠다.
  var key: String { "\(Int((start * 10).rounded()))|\(live)|\(whisper)" }
}

/// 표본 묶음. 세션 폴더의 `gold.json` 에 담긴다.
struct GoldSet: Codable, Sendable {
  var samples: [GoldSample] = []

  static let filename = "gold.json"

  static func load(from dir: URL) -> GoldSet {
    let url = dir.appendingPathComponent(filename)
    guard let data = try? Data(contentsOf: url) else { return GoldSet() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let set = try? decoder.decode(GoldSet.self, from: data) else {
      // 읽기 실패를 빈 묶음으로 돌려주면, 다음 저장이 사용자의 표본을 통째로 덮는다.
      // 사람이 소리를 들으며 만든 데이터라 다시 만들 수 없다. 원본을 먼저 지킨다.
      let backup = dir.appendingPathComponent("gold.broken-\(Int(Date().timeIntervalSince1970)).json")
      try? data.write(to: backup, options: .atomic)
      logError("표본 파일을 읽지 못했습니다: \(url.lastPathComponent) — "
             + "원본을 \(backup.lastPathComponent) 로 옮겨 두었습니다.")
      return GoldSet()
    }
    return set
  }

  func save(to dir: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return }
    try? data.write(to: dir.appendingPathComponent(Self.filename), options: .atomic)
  }

  /// 같은 지점이면 덮어쓰고, 아니면 추가한다.
  mutating func put(_ sample: GoldSample) {
    if let i = samples.firstIndex(where: { $0.key == sample.key }) {
      samples[i] = sample
    } else {
      samples.append(sample)
    }
  }

  mutating func remove(key: String) {
    samples.removeAll { $0.key == key }
  }

  /// 이미 판정한 지점들의 키
  var judged: Set<String> { Set(samples.map(\.key)) }
}

// MARK: - 채점

enum GoldScore {

  /// 표본으로 두 전사기의 성적을 낸다.
  ///
  /// 이 숫자가 있어야 "2분 조각이 30초 조각보다 낫다" 같은 주장을 **재서 확인**할 수 있다.
  /// 지금까지는 그걸 못 해서 개선안이 전부 짐작이었다.
  static func summary(_ samples: [GoldSample]) -> [String: Any] {
    // 옛 형식(schema 1)은 정규화된 글자가 정답으로 박혀 있어 채점에 쓸 수 없다.
    // 세어서 보여는 주되 성적에는 넣지 않는다.
    let stale = samples.filter { $0.formatVersion < 2 }.count
    let usable = samples.filter { $0.formatVersion >= 2 }
    let judged = usable.filter { $0.verdict != "unclear" }
    let live = judged.filter { $0.verdict == "live" }.count
    let whisper = judged.filter { $0.verdict == "whisper" }.count
    let both = judged.filter { $0.verdict == "both" }.count
    let n = max(judged.count, 1)

    var byKind: [String: Any] = [:]
    for kind in ["script", "missing", "differ"] {
      let group = judged.filter { $0.kind == kind }
      guard !group.isEmpty else { continue }
      byKind[kind] = [
        "total": group.count,
        "live": group.filter { $0.verdict == "live" }.count,
        "whisper": group.filter { $0.verdict == "whisper" }.count,
        "both": group.filter { $0.verdict == "both" }.count,
      ]
    }

    return [
      "total": usable.count,
      "stale": stale,
      "judged": judged.count,
      "live": live,
      "whisper": whisper,
      "both": both,
      "liveRatio": Double(live) / Double(n),
      "whisperRatio": Double(whisper) / Double(n),
      "bothRatio": Double(both) / Double(n),
      "byKind": byKind,
    ]
  }

  /// 저장 폴더 전체를 훑어 표본을 모은다. 수업이 쌓일수록 이 숫자가 믿을 만해진다.
  static func collectAll(baseDir: URL) -> [(session: String, samples: [GoldSample])] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: baseDir.path) else { return [] }
    return names.sorted().compactMap { name in
      let dir = baseDir.appendingPathComponent(name, isDirectory: true)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
      let set = GoldSet.load(from: dir)
      return set.samples.isEmpty ? nil : (name, set.samples)
    }
  }
}

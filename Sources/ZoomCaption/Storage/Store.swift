import Foundation

/// 예전 기록에 `me`(마이크) 트랙이 섞여 있을 수 있어 남겨 둔다. 지금은 lecture 만 쓴다.
enum Track: String, Codable, Sendable {
  case lecture
  case me

  var label: String { self == .lecture ? "강의" : "나" }
}

/// 낱말 하나가 실제로 들린 구간. 본문에서의 위치를 함께 들고 있다.
///
/// 왜 필요한가 — 실시간 기록은 한 줄이 **14.1초에 89자**다(실측 중앙값).
/// 줄의 시작·끝 시각만 알면 그 안의 어느 낱말이 언제 나왔는지 알 길이 없어,
/// Whisper(3.3초 단위)와 맞출 때 ±1초가 그냥 깔린다. 그 대부분은 **오차가 아니라
/// 해상도 부족**이다. SpeechTranscriber 는 낱말마다 시각을 주는데 여태 버리고 있었다.
struct WordTime: Codable, Sendable, Equatable {
  var offset: Int        // 세그먼트 본문에서의 글자 위치
  var length: Int
  var start: Double      // 세션 시작 기준 초
  var end: Double
}

struct Segment: Codable, Sendable, Identifiable {
  var id: Int
  var track: Track
  var start: Double      // 세션 시작 기준 초
  var end: Double
  var text: String
  var edited: Bool = false
  /// 낱말별 시각. 실시간 기록에만 있다(Whisper 는 줄 자체가 짧아 필요 없다).
  /// 옛 세션에는 없으므로 반드시 Optional 이어야 한다 —
  /// 기본값만 준 비Optional 은 디코딩을 통째로 실패시킨다. (gold.json 에서 겪었다.)
  var words: [WordTime]?
}

/// 디스크에 저장되는 세션 원본. .md/.srt 는 이걸로부터 파생된다.
struct SessionFile: Codable {
  var title: String
  var createdAt: Date
  var updatedAt: Date
  var segments: [Segment]
  var nextID: Int
  var summary: String?
  var domainTerms: [String]
  var domainSource: String?
  /// 지금까지 기록된 총 길이. 이어 적기를 하면 여기서부터 타임스탬프가 이어진다.
  var duration: Double
  /// 마지막 요약이 어디까지 훑었는지(초). 다음 요약을 이어서 돌릴 때 시작점으로 쓴다.
  var lastSummarizedAt: Double?
  /// Whisper 가 만든 정식 기록. 실시간 자막(segments)과 나란히 보관한다.
  var whisperSegments: [Segment]?
  var whisperAt: Date?
  /// 이 수업에서 저장한 요약 파일 경로들. 1교시·2교시로 나뉘면 여러 개가 된다.
  var summaryFiles: [String]?
  /// 손으로 고친 정답지. 전사 품질을 숫자로 재는 유일한 기준이다.
  var reference: Reference?
  /// 문맥 교정을 적용하기 전의 원문. 되돌리기용. (세그먼트 id → 원래 텍스트)
  var preCorrection: [String: String]?
}

/// 정답지 — 어느 구간을 사람이 직접 맞게 고쳤는지.
///
/// 이게 없으면 "합치는 게 나은가" 를 판단할 방법이 없다. 실시간과 Whisper 중
/// 어느 쪽이 맞는지는 감으로 정할 수 없고, 융합이 Whisper 단독보다 나은지도 마찬가지다.
struct Reference: Codable, Sendable {
  var from: Double
  var to: Double
  var text: String
  var updatedAt: Date
}

/// 세션 전체 상태. 웹 UI와 파일 저장이 모두 여기서 읽는다.
final class TranscriptStore: @unchecked Sendable {
  private let lock = NSLock()
  private var segments: [Segment] = []
  private var volatile: [Track: String] = [:]
  private var nextID = 1

  private(set) var createdAt = Date()
  private(set) var startedAt: Date?
  /// 이어 적기 시 새 발화에 더해지는 시간 오프셋
  private(set) var timeBase: Double = 0

  var title: String = "Zoom 수업"
  var summary: String?
  /// 마지막 요약이 훑은 끝 지점(초)
  var lastSummarizedAt: Double?
  var domainTerms: [String] = []
  var domainSource: String?
  var sessionDir: URL?

  /// Whisper 가 만든 정식 기록.
  private(set) var whisperSegments: [Segment] = []
  private(set) var whisperAt: Date?
  /// 저장한 요약 파일 경로. 이어 적기로 세션을 다시 열어도 따라온다.
  private(set) var summaryFiles: [String] = []
  /// 손으로 고친 정답지 구간
  var reference: Reference?
  /// 교정 적용 전 원문 보관. 한 번만 담고, 되돌리면 비운다.
  private(set) var preCorrection: [Int: String] = [:]
  var hasCorrections: Bool { lock.withLock { !preCorrection.isEmpty } }
  /// Whisper 줄의 id 는 실시간 자막과 겹치지 않게 따로 띄운다.
  private var nextWhisperID = 1_000_000

  /// 저장·요약·내보내기의 기준이 되는 기록.
  /// Whisper 가 있으면 그쪽이다 — 실측에서 영문 식별자를 24종 살려내는 동안
  /// 실시간 전사기는 0종이었다. 없으면 실시간 기록으로 떨어진다.
  var primarySegments: [Segment] {
    let w = lock.withLock { whisperSegments }
    return w.isEmpty ? allSegments : w
  }
  var hasWhisper: Bool { lock.withLock { !whisperSegments.isEmpty } }

  /// 변경이 생길 때마다 호출된다 (SSE 브로드캐스트용)
  var onChange: (@Sendable (StoreEvent) -> Void)?

  // MARK: - 수명주기

  /// 완전히 새 세션
  func reset(title: String) {
    lock.withLock {
      segments.removeAll()
      volatile.removeAll()
      nextID = 1
      timeBase = 0
      createdAt = Date()
      startedAt = nil
      self.title = title
      summary = nil
      lastSummarizedAt = nil
      domainTerms = []
      domainSource = nil
      sessionDir = nil
      whisperSegments = []
      whisperAt = nil
      summaryFiles = []
      reference = nil
      preCorrection = [:]
      nextWhisperID = 1_000_000
    }
  }

  /// 저장된 세션을 이어받는다. 새 발화는 기존 기록 뒤에 붙는다.
  func adopt(_ file: SessionFile, dir: URL) {
    lock.withLock {
      segments = file.segments
      volatile.removeAll()
      nextID = max(file.nextID, (file.segments.map(\.id).max() ?? 0) + 1)
      createdAt = file.createdAt
      startedAt = nil
      title = file.title
      summary = file.summary
      lastSummarizedAt = file.lastSummarizedAt
      domainTerms = file.domainTerms
      domainSource = file.domainSource
      sessionDir = dir
      whisperSegments = file.whisperSegments ?? []
      whisperAt = file.whisperAt
      summaryFiles = file.summaryFiles ?? []
      reference = file.reference
      preCorrection = Dictionary(uniqueKeysWithValues:
        (file.preCorrection ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
      nextWhisperID = max(1_000_000, (whisperSegments.map(\.id).max() ?? 999_999) + 1)
      // 마지막 발화 끝 + 2초 여백부터 이어 붙인다. 두 목록 모두 본다.
      timeBase = max(file.duration, lastEndLocked()) + 2
    }
  }

  /// 녹음 구간 시작. 이어 적기라면 timeBase 가 유지된다.
  func beginRecording() {
    lock.withLock { startedAt = Date() }
  }

  /// 기록이 실제로 어디까지 갔는지. **두 목록을 모두** 봐야 한다.
  ///
  /// 실시간 자막과 Whisper 는 끝나는 지점이 다르다 — 실측에서 같은 구간에 대해
  /// 실시간 49줄 / Whisper 64줄이었고, 실시간이 0줄인데 Whisper 만 나온 적도 있다.
  /// 한쪽만 보고 이어 적기 기준을 잡으면 새 녹음이 기존 기록 위에 겹쳐 앉는다.
  private func lastEndLocked() -> Double {
    max(segments.map(\.end).max() ?? 0, whisperSegments.map(\.end).max() ?? 0)
  }

  func endRecording() {
    lock.withLock {
      // 다음 구간이 이어붙을 수 있도록 timeBase 를 끌어올린다.
      timeBase = max(timeBase, lastEndLocked()) + 2
      startedAt = nil
    }
  }

  // MARK: - 기록

  @discardableResult
  func appendFinal(track: Track, start: Double, end: Double, text: String,
                   words: [WordTime] = []) -> Segment? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // 인식기가 가끔 "." 처럼 구두점만 내보낸다. 자막으로는 쓸모가 없으니 버린다.
    guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }

    let seg: Segment = lock.withLock {
      // 낱말 시각도 이어 적기 기준으로 옮긴다. 안 그러면 줄과 낱말이 서로 다른 시계를 쓴다.
      let shifted = words.map {
        WordTime(offset: $0.offset, length: $0.length,
                 start: $0.start + timeBase, end: $0.end + timeBase)
      }
      let s = Segment(id: nextID, track: track,
                      start: start + timeBase, end: end + timeBase, text: trimmed,
                      words: shifted.isEmpty ? nil : shifted)
      nextID += 1
      segments.append(s)
      segments.sort { $0.start < $1.start }
      volatile[track] = ""
      return s
    }
    onChange?(.final(seg))
    return seg
  }

  func setVolatile(track: Track, text: String) {
    lock.withLock { volatile[track] = text }
    onChange?(.volatile(track, text))
  }

  // MARK: - 편집

  @discardableResult
  func updateSegment(id: Int, text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let ok: Bool = lock.withLock {
      guard let idx = segments.firstIndex(where: { $0.id == id }) else { return false }
      if trimmed.isEmpty {
        segments.remove(at: idx)
      } else {
        segments[idx].text = trimmed
        segments[idx].edited = true
      }
      return true
    }
    if ok { onChange?(.edited(id, trimmed)) }
    return ok
  }

  @discardableResult
  func deleteSegments(ids: [Int]) -> Int {
    let set = Set(ids)
    let removed: Int = lock.withLock {
      let before = segments.count
      segments.removeAll { set.contains($0.id) }
      return before - segments.count
    }
    if removed > 0 { onChange?(.deleted(ids)) }
    return removed
  }

  /// 구간(초) 안에 시작하는 발화를 모두 지운다.
  @discardableResult
  func deleteRange(from: Double, to: Double) -> Int {
    let ids = allSegments.filter { $0.start >= from && $0.start <= to }.map(\.id)
    return deleteSegments(ids: ids)
  }

  // MARK: - 읽기

  var allSegments: [Segment] { lock.withLock { segments } }
  var volatileTexts: [Track: String] { lock.withLock { volatile } }
  /// 저장할 게 없는지. Whisper 기록만 있고 실시간 자막이 비어 있는 경우도 있어서
  /// 둘 다 봐야 한다 — 한쪽만 보면 정지할 때 "기록이 비어 있다"며 그냥 버린다.
  var isEmpty: Bool { lock.withLock { segments.isEmpty && whisperSegments.isEmpty } }
  var duration: Double { lock.withLock { max(timeBase, lastEndLocked()) } }

  /// 현재 녹음 구간의 경과 시간 (UI 타이머용)
  var elapsed: Double {
    lock.withLock { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
  }

  func snapshot() -> SessionFile {
    lock.withLock {
      SessionFile(title: title, createdAt: createdAt, updatedAt: Date(),
                  segments: segments, nextID: nextID, summary: summary,
                  domainTerms: domainTerms, domainSource: domainSource,
                  duration: max(timeBase, lastEndLocked()),
                  lastSummarizedAt: lastSummarizedAt,
                  whisperSegments: whisperSegments.isEmpty ? nil : whisperSegments,
                  whisperAt: whisperAt,
                  summaryFiles: summaryFiles.isEmpty ? nil : summaryFiles,
                  reference: reference,
                  preCorrection: preCorrection.isEmpty ? nil
                    : Dictionary(uniqueKeysWithValues: preCorrection.map { (String($0.key), $0.value) }))
    }
  }

  /// 구간 안의 발화를 이어 붙인 평문. 정답지 대조에 쓴다.
  func plainRange(_ list: [Segment], from: Double, to: Double) -> String {
    list.filter { $0.start >= from && $0.start < to }
        .sorted { $0.start < $1.start }
        .map(\.text).joined(separator: " ")
  }

  /// 교정을 적용한다. 위치가 안 맞으면(그 사이 편집됐다면) 건너뛴다 — 엉뚱한 데를 고치면 안 된다.
  @discardableResult
  func applyCorrection(segID: Int, rangeStart: Int, rangeEnd: Int,
                       before: String, after: String) -> Bool {
    lock.withLock {
      guard let idx = whisperSegments.firstIndex(where: { $0.id == segID }) else { return false }
      let text = whisperSegments[idx].text
      guard rangeStart >= 0, rangeEnd <= text.count, rangeStart < rangeEnd else { return false }
      let a = text.index(text.startIndex, offsetBy: rangeStart)
      let b = text.index(text.startIndex, offsetBy: rangeEnd)
      // 제안을 만든 시점의 원문과 지금이 같은지 확인한다. 다르면 손대지 않는다.
      guard String(text[a..<b]) == before else { return false }
      if preCorrection[segID] == nil { preCorrection[segID] = text }
      whisperSegments[idx].text = text.replacingCharacters(in: a..<b, with: after)
      whisperSegments[idx].edited = true
      return true
    }
  }

  /// 교정 전 원문으로 되돌린다.
  @discardableResult
  func revertCorrections() -> Int {
    lock.withLock {
      var n = 0
      for (segID, original) in preCorrection {
        if let idx = whisperSegments.firstIndex(where: { $0.id == segID }) {
          whisperSegments[idx].text = original
          n += 1
        }
      }
      preCorrection.removeAll()
      return n
    }
  }

  /// 요약을 파일로 저장했다는 사실을 기록해 둔다.
  func rememberSummaryFile(_ url: URL) {
    lock.withLock {
      if !summaryFiles.contains(url.path) { summaryFiles.append(url.path) }
    }
  }

  /// 지정한 시각 이후의 발화만 고른다. from 이 nil 이면 전체.
  /// 요약·내보내기가 쓰는 경로라 Whisper 기록이 있으면 그쪽을 본다.
  func segments(from: Double?) -> [Segment] {
    let base = primarySegments
    guard let from else { return base }
    return base.filter { $0.start >= from }
  }

  /// 요약·저장용 평문. 시간순으로 잇는다.
  func plainText(from: Double? = nil, includeTimestamps: Bool = true) -> String {
    segments(from: from).map { seg in
      let stamp = includeTimestamps ? "[\(Self.clock(seg.start))] " : ""
      return "\(stamp)\(seg.text)"
    }.joined(separator: "\n")
  }

  // MARK: - Whisper 재전사

  /// 녹음 중 Whisper 가 조각을 끝낼 때마다 붙인다. 시간순을 유지한다.
  @discardableResult
  func appendWhisper(_ lines: [WhisperLive.Line]) -> [Segment] {
    guard !lines.isEmpty else { return [] }
    return lock.withLock {
      var added: [Segment] = []
      for line in lines {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
        let seg = Segment(id: nextWhisperID, track: .lecture,
                          start: line.start, end: line.end, text: text)
        nextWhisperID += 1
        whisperSegments.append(seg)
        added.append(seg)
      }
      whisperSegments.sort { $0.start < $1.start }
      if !added.isEmpty { whisperAt = Date() }
      return added
    }
  }

  @discardableResult
  func updateWhisperSegment(id: Int, text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      guard let idx = whisperSegments.firstIndex(where: { $0.id == id }) else { return false }
      if trimmed.isEmpty { whisperSegments.remove(at: idx) }
      else { whisperSegments[idx].text = trimmed; whisperSegments[idx].edited = true }
      return true
    }
  }

  @discardableResult
  func deleteWhisperSegments(ids: [Int]) -> Int {
    let set = Set(ids)
    return lock.withLock {
      let before = whisperSegments.count
      whisperSegments.removeAll { set.contains($0.id) }
      return before - whisperSegments.count
    }
  }

  /// 무음 위에 적힌 것으로 판정된 줄을 **되돌릴 수 있게** 치운다.
  ///
  /// 자동 판정이라 사람이 못 보고 지나칠 수 있다. 그래서 지우는 게 아니라 옆에 치워 두고,
  /// 한 번에 되돌릴 수 있게 한다. 근거가 아직 환각 6건뿐이라 되돌릴 길은 반드시 있어야 한다.
  private(set) var droppedQuiet: [Segment] = []
  var hasDroppedQuiet: Bool { lock.withLock { !droppedQuiet.isEmpty } }

  @discardableResult
  func dropQuiet(ids: [Int]) -> Int {
    let set = Set(ids)
    return lock.withLock {
      let hit = whisperSegments.filter { set.contains($0.id) }
      guard !hit.isEmpty else { return 0 }
      droppedQuiet.append(contentsOf: hit)
      whisperSegments.removeAll { set.contains($0.id) }
      return hit.count
    }
  }

  @discardableResult
  func restoreQuiet() -> Int {
    lock.withLock {
      guard !droppedQuiet.isEmpty else { return 0 }
      let n = droppedQuiet.count
      whisperSegments.append(contentsOf: droppedQuiet)
      whisperSegments.sort { $0.start < $1.start }
      droppedQuiet.removeAll()
      return n
    }
  }

  /// 그 시각 언저리의 실시간 기록. 무음 의심 줄을 가릴 두 번째 신호로 쓴다.
  func liveTextNear(start: Double, end: Double, pad: Double = 30) -> String {
    lock.withLock {
      segments
        .filter { $0.end >= start - pad && $0.start <= end + pad }
        .sorted { $0.start < $1.start }
        .map(\.text)
        .joined(separator: " ")
    }
  }

  // MARK: - 내보내기

  static func clock(_ t: Double) -> String {
    let total = Int(t.rounded(.down))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
  }

  private static func srtStamp(_ t: Double) -> String {
    let total = max(0, t)
    let h = Int(total) / 3600, m = (Int(total) % 3600) / 60, s = Int(total) % 60
    let ms = Int((total - total.rounded(.down)) * 1000)
    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
  }

  func srt() -> String {
    primarySegments.enumerated().map { idx, seg in
      let end = max(seg.end, seg.start + 0.4)
      return """
      \(idx + 1)
      \(Self.srtStamp(seg.start)) --> \(Self.srtStamp(end))
      \(seg.track == .me ? "(나) " : "")\(seg.text)
      """
    }.joined(separator: "\n\n") + "\n"
  }

  /// 실시간 전사기 기록만 담은 문서. Whisper 기록과 나란히 남겨 대조에 쓴다.
  func liveMarkdown() -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "ko_KR")
    df.dateFormat = "yyyy년 M월 d일 (E) HH:mm"
    var out = "# \(title) — 실시간 자막 (SpeechTranscriber)\n\n"
    out += "- 일시: \(df.string(from: createdAt))\n"
    out += "- 이 파일은 대조용입니다. 정식 기록은 transcript.md 입니다.\n\n"
    for seg in allSegments {
      out += "**[\(Self.clock(seg.start))] \(seg.track.label)** — \(seg.text)\n\n"
    }
    return out
  }

  /// 요약만 담은 문서. 전체 기록 없이 요약 파일로 따로 저장할 때 쓴다.
  func markdownSummaryOnly() -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "ko_KR")
    df.dateFormat = "yyyy년 M월 d일 (E) HH:mm"

    var out = "# \(title) — 요약\n\n- 일시: \(df.string(from: createdAt))\n"
    if let at = lastSummarizedAt {
      out += "- 요약 범위: \(Self.clock(at)) 까지\n"
    }
    if let src = domainSource { out += "- 교안: \(src)\n" }
    out += "\n"
    out += (summary ?? "_요약이 없습니다._")
    return out + "\n"
  }

  func markdown() -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "ko_KR")
    df.dateFormat = "yyyy년 M월 d일 (E) HH:mm"

    let segs = primarySegments
    var out = """
    # \(title)

    - 일시: \(df.string(from: createdAt))
    - 길이: \(Self.clock(duration))
    - 발화 수: \(segs.count)
    - 전사: \(hasWhisper ? "Whisper (실시간 자막은 transcript_live.md)" : "실시간 전사기")

    """
    if let src = domainSource {
      out += "- 교안: \(src)\(domainTerms.isEmpty ? "" : " (용어 \(domainTerms.count)개 반영)")\n"
    }
    out += "\n"

    if let summary, !summary.isEmpty {
      let hasOwnHeading = summary.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
      out += hasOwnHeading ? "\(summary)\n\n" : "## 요약\n\n\(summary)\n\n"
    }
    out += "## 전체 기록\n\n"
    for seg in segs {
      out += "**[\(Self.clock(seg.start))] \(seg.track.label)** — \(seg.text)\n\n"
    }
    return out
  }
}

enum StoreEvent: Sendable {
  case final(Segment)
  case volatile(Track, String)
  case edited(Int, String)
  case deleted([Int])
}

import Foundation

/// 두 전사 결과(실시간·Whisper)를 글자 단위로 맞춰 어디서 갈리는지 찾는다.
///
/// 세그먼트 경계로는 맞출 수 없다 — 실측에서 실시간은 줄당 14.1초, Whisper 는 4.8초라
/// 경계가 아예 다르다. 그래서 텍스트를 이어 붙여 글자 단위로 정렬한다.
///
/// 실측(600초 실제 강의): 정규화 후 **76.3% 가 일치**했고, 두 기록의 시각은
/// 거의 완벽히 겹쳤다(겹침 비율 중앙값 1.00, 안 겹치는 줄 0개).
/// 그래서 일치 구간을 앵커로 삼는 방식이 잘 먹는다.
enum Alignment {

  /// 갈리는 지점의 종류. 처리 방법이 갈래마다 다르다.
  enum Kind: String, Sendable {
    case same       // 양쪽이 같다. 손댈 것 없음
    case script     // 같은 말인데 표기만 다르다 (해시맵 ↔ hashmap)
    case missing    // 한쪽에만 있다 (받아쓰기가 빠진 구간)
    case differ     // 양쪽 다 한글인데 내용이 다르다
  }

  struct Block: Sendable {
    var kind: Kind
    var live: String        // 비교용 정규화 텍스트
    var whisper: String
    var start: Double
    var end: Double
    /// 교정을 실제로 적용하려면 원문 어디인지 알아야 한다.
    /// 정규화 과정에서 공백·문장부호를 뺐기 때문에 문자열 치환으로는 못 찾는다.
    /// 한 세그먼트 안에 들어오는 블록만 채운다 — 여러 줄에 걸치면 안전하게 손대기 어렵다.
    var segID: Int = -1
    var rangeStart: Int = 0      // 세그먼트 원문에서의 문자 오프셋
    var rangeEnd: Int = 0        // 끝(미포함)
    var whisperRaw: String = ""  // 그 구간의 원문 그대로 (공백·부호 포함)
    var liveRaw: String = ""     // 실시간 쪽 원문
    var applicable: Bool { segID >= 0 && rangeEnd > rangeStart }

    /// 본문에 밑줄을 그어 사람에게 물어볼 값어치가 있는 자리인가.
    ///
    /// 실측(10분 강의, 갈린 블록 194개)으로 정한 기준이다:
    /// ```
    /// 전부 표시        3.1초에 1개   ← 온통 밑줄이라 글을 못 읽는다
    /// differ 만        5.3초에 1개
    /// differ 3자 이상 15.5초에 1개   ← 이 정도가 읽힌다
    /// ```
    /// `script`(해시맵↔hashmap 같은 표기 차이)는 거의 항상 Whisper 가 맞아서
    /// 물어볼 값어치가 없다 — 켜고 싶으면 `includeScript` 로 연다.
    /// `missing`(한쪽에만 있는 구간)은 실시간에만 있는 글자가 전체의 1.9% 이고
    /// 그나마 대부분 군말이라 넣지 않는다.
    func worthAsking(includeScript: Bool = false, minLength: Int = 3) -> Bool {
      guard applicable, !whisperRaw.isEmpty else { return false }
      switch kind {
      case .differ:  return min(live.count, whisper.count) >= minLength
      case .script:  return includeScript && min(live.count, whisper.count) >= 2
      case .same, .missing: return false
      }
    }
  }

  // MARK: - 정규화

  /// 비교용으로만 쓰는 축약형. 띄어쓰기와 문장부호는 양쪽 다 못 믿는다.
  /// 원본 글자와 시각을 되찾을 수 있게 인덱스를 같이 들고 다닌다.
  private struct Flat {
    var chars: [Character] = []
    var time: [Double] = []      // 글자마다 그 글자가 속한 발화의 시작 시각
    var origin: [Int] = []       // 원본 문자열에서의 위치(세그먼트 단위로 잘라 쓰기 위함)
    var pieces: [String] = []    // 세그먼트별 원문
    var ids: [Int] = []          // 세그먼트별 id
    var pieceOf: [Int] = []      // 글자 → 몇 번째 세그먼트인지
  }

  private static func flatten(_ segments: [Segment]) -> Flat {
    var f = Flat()
    for (index, seg) in segments.enumerated() {
      f.ids.append(seg.id)
      f.pieces.append(seg.text)

      // 글자 위치에 비례해 시각을 나눠 준다.
      //
      // 세그먼트 하나가 실측 4~9초라, 시작 시각만 붙이면 그 안의 여러 지점이 전부
      // 같은 시각으로 뭉개진다. 실제로 한 세그먼트 안의 갈린 지점 네 곳이 모두 0.0초로
      // 나왔다. 그러면 그 자리 소리를 들으러 갈 수가 없다 — 표본을 모으려면 시각이 맞아야 한다.
      let letters = seg.text.reduce(into: 0) { n, c in if c.isLetter || c.isNumber { n += 1 } }
      let span = max(0, seg.end - seg.start)
      var seen = 0

      var offset = 0
      for ch in seg.text {
        defer { offset += 1 }
        // 한글·영문·숫자만 남긴다. 그 외(공백·문장부호)는 비교에서 제외.
        guard ch.isLetter || ch.isNumber else { continue }
        f.chars.append(Character(ch.lowercased()))
        // 낱말 시각이 있으면 그게 진짜다. 보간은 없을 때만 쓴다.
        f.time.append(wordTime(seg, offset: offset)
          ?? seg.start + (letters > 1 ? span * Double(seen) / Double(letters) : 0))
        seen += 1
        f.origin.append(offset)
        f.pieceOf.append(index)
      }
    }
    return f
  }

  /// 그 글자가 실제로 들린 시각. 낱말 시각이 없으면 nil.
  ///
  /// 보간은 한 줄을 고르게 발음했다고 치는 건데, 실시간 기록은 한 줄이 **14.1초에 89자**라
  /// (실측 중앙값) 그 가정이 크게 틀어진다. 두 기록의 시각 차를 재 보니 계통 오차는 거의
  /// 없고(중앙값 +0.02~+0.47초) **흩어짐이 ±1초**였는데, 그 상당 부분이 이 보간 탓이다.
  private static func wordTime(_ seg: Segment, offset: Int) -> Double? {
    guard let words = seg.words, !words.isEmpty else { return nil }
    if let w = words.first(where: { offset >= $0.offset && offset < $0.offset + $0.length }) {
      let within = w.length > 1 ? Double(offset - w.offset) / Double(w.length) : 0
      return w.start + (w.end - w.start) * within
    }
    // 낱말 사이(공백·부호)면 가장 가까운 낱말에 붙인다.
    if let before = words.last(where: { $0.offset + $0.length <= offset }) { return before.end }
    return words.first(where: { $0.offset > offset })?.start
  }

  // MARK: - 정렬

  /// 가장 긴 공통 구간을 찾아 앵커로 삼고, 좌우로 재귀한다.
  /// 일치율이 높을수록(우리 데이터는 76%) 앵커가 촘촘해 금방 끝난다.
  private static func matchingBlocks(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>,
                                     into out: inout [(a: Int, b: Int, len: Int)]) {
    guard !a.isEmpty, !b.isEmpty else { return }
    // 가장 긴 공통 부분문자열 — 앞 행만 들고 도는 DP
    var previous = [Int](repeating: 0, count: b.count + 1)
    var current = previous
    var bestLen = 0, bestA = a.startIndex, bestB = b.startIndex

    for (i, ca) in a.enumerated() {
      for (j, cb) in b.enumerated() {
        current[j + 1] = (ca == cb) ? previous[j] + 1 : 0
        if current[j + 1] > bestLen {
          bestLen = current[j + 1]
          bestA = a.startIndex + i - bestLen + 1
          bestB = b.startIndex + j - bestLen + 1
        }
      }
      swap(&previous, &current)
    }
    // 너무 짧은 일치는 우연이라 앵커로 쓰지 않는다. 한글 두 글자면 흔하게 겹친다.
    guard bestLen >= 3 else { return }

    matchingBlocks(a[a.startIndex..<bestA], b[b.startIndex..<bestB], into: &out)
    out.append((bestA, bestB, bestLen))
    matchingBlocks(a[(bestA + bestLen)...], b[(bestB + bestLen)...], into: &out)
  }

  // MARK: - 분류

  private static func hasHangul(_ s: some StringProtocol) -> Bool {
    s.contains { ("가"..."힣").contains($0) }
  }
  private static func hasLatin(_ s: some StringProtocol) -> Bool {
    s.contains { $0.isASCII && $0.isLetter }
  }

  private static func classify(live: String, whisper: String) -> Kind {
    if live.isEmpty || whisper.isEmpty { return .missing }
    // 한쪽만 영문이면 같은 말을 표기만 달리 적은 경우가 대부분이다.
    // 실측: 해시맵↔hashmap, 해쉬셋↔hashset, 리스트↔list — 전부 같은 말이었다.
    if hasLatin(whisper) != hasLatin(live) { return .script }
    return .differ
  }

  // MARK: - 진입점

  /// 창 하나의 길이(초). 이 안에서만 글자를 맞춘다.
  ///
  /// 통짜로 맞추면 글자 수의 곱에 비례해 느려진다 — 2시간 강의면 양쪽 2.5만 자라
  /// 새 문장이 올 때마다 다시 돌릴 수 없다. 다행히 두 기록의 시각이 잘 맞아서
  /// (실측: 2분 창마다 글자 수 비율 중앙값 0.87~1.00) 창으로 잘라도 안전하다.
  static let windowSeconds: Double = 120

  /// 양쪽 기록이 다 도착한 시각. 이 뒤는 아직 비교하면 안 된다.
  ///
  /// Whisper 는 30초 조각을 뒤에서 따라오기 때문에 항상 실시간보다 뒤처진다.
  /// 그 구간을 그냥 비교하면 **아직 안 온 것**이 전부 "누락" 으로 뜬다 —
  /// 실측(1014 세션)에서 Whisper 가 678초에 멈췄는데 실시간은 987초까지 가 있어,
  /// 그대로 비교하면 5분치가 통째로 갈린 걸로 잡혔다.
  ///
  /// - Parameter margin: 마지막 조각이 아직 다듬어지는 중일 수 있어 더 물러선다.
  static func settledUntil(live: [Segment], whisper: [Segment],
                           margin: Double = 30) -> Double {
    guard let liveEnd = live.map(\.end).max(),
          let whisperEnd = whisper.map(\.end).max() else { return 0 }
    return max(0, min(liveEnd, whisperEnd) - margin)
  }

  /// 시각 창 단위로 잘라 맞춘다. 창마다 독립이라 비용이 창 하나 크기로 묶인다.
  ///
  /// - Parameter until: 이 시각까지만 본다. 기본은 제한 없음(정지 후 전체 대조).
  static func compareWindowed(live: [Segment], whisper: [Segment],
                              window: Double = windowSeconds,
                              until: Double = .infinity) -> [Block] {
    let l = live.filter { $0.start < until }.sorted { $0.start < $1.start }
    let w = whisper.filter { $0.start < until }.sorted { $0.start < $1.start }
    guard !l.isEmpty || !w.isEmpty else { return [] }

    let last = max(l.last?.start ?? 0, w.last?.start ?? 0)
    var out: [Block] = []
    var t: Double = 0
    while t <= last {
      let hi = t + window
      // 세그먼트는 시작 시각이 든 창에 넣는다. 경계를 걸친 문장이 쪼개지지 않는다.
      let lw = l.filter { $0.start >= t && $0.start < hi }
      let ww = w.filter { $0.start >= t && $0.start < hi }
      if !lw.isEmpty || !ww.isEmpty { out += compare(live: lw, whisper: ww) }
      t = hi
    }
    return out
  }

  static func compare(live: [Segment], whisper: [Segment]) -> [Block] {
    let L = flatten(live.sorted { $0.start < $1.start })
    let W = flatten(whisper.sorted { $0.start < $1.start })
    guard !L.chars.isEmpty || !W.chars.isEmpty else { return [] }

    var anchors: [(a: Int, b: Int, len: Int)] = []
    matchingBlocks(L.chars[...], W.chars[...], into: &anchors)
    anchors.append((L.chars.count, W.chars.count, 0))   // 끝을 닫는 감시자

    var blocks: [Block] = []
    var i = 0, j = 0
    for anchor in anchors {
      if anchor.a > i || anchor.b > j {
        let lt = String(L.chars[i..<anchor.a])
        let wt = String(W.chars[j..<anchor.b])
        let t = timeSpan(L, i..<anchor.a, W, j..<anchor.b)
        var block = Block(kind: classify(live: lt, whisper: wt),
                          live: lt, whisper: wt, start: t.0, end: t.1)
        locate(W, j..<anchor.b, into: &block)
        block.liveRaw = rawSpan(L, i..<anchor.a) ?? block.live
        blocks.append(block)
      }
      if anchor.len > 0 {
        let text = String(L.chars[anchor.a..<(anchor.a + anchor.len)])
        let t = timeSpan(L, anchor.a..<(anchor.a + anchor.len),
                         W, anchor.b..<(anchor.b + anchor.len))
        blocks.append(Block(kind: .same, live: text, whisper: text, start: t.0, end: t.1))
      }
      i = anchor.a + anchor.len
      j = anchor.b + anchor.len
    }
    return blocks
  }

  /// 정규화 인덱스 범위를 원문 위치로 되돌린다.
  private static func locate(_ W: Flat, _ range: Range<Int>, into block: inout Block) {
    guard !range.isEmpty, range.upperBound <= W.pieceOf.count else { return }
    let piece = W.pieceOf[range.lowerBound]
    // 여러 세그먼트에 걸치면 손대지 않는다. 잘못 이어 붙이면 문장이 깨진다.
    guard W.pieceOf[range.lowerBound..<range.upperBound].allSatisfy({ $0 == piece }) else { return }
    let lo = W.origin[range.lowerBound]
    let hi = W.origin[range.upperBound - 1] + 1
    let text = W.pieces[piece]
    guard lo >= 0, hi <= text.count, lo < hi else { return }
    let a = text.index(text.startIndex, offsetBy: lo)
    let b = text.index(text.startIndex, offsetBy: hi)
    block.segID = W.ids[piece]
    block.rangeStart = lo
    block.rangeEnd = hi
    block.whisperRaw = String(text[a..<b])
  }

  /// 정규화 범위에 대응하는 원문 조각. 세그먼트를 넘나들면 이어 붙인다(표시용이라 안전).
  private static func rawSpan(_ F: Flat, _ range: Range<Int>) -> String? {
    guard !range.isEmpty, range.upperBound <= F.pieceOf.count else { return nil }
    var out = ""
    var i = range.lowerBound
    while i < range.upperBound {
      let piece = F.pieceOf[i]
      var j = i
      while j < range.upperBound, F.pieceOf[j] == piece { j += 1 }
      let text = F.pieces[piece]
      let lo = F.origin[i], hi = F.origin[j - 1] + 1
      if lo < hi, hi <= text.count {
        let a = text.index(text.startIndex, offsetBy: lo)
        let b = text.index(text.startIndex, offsetBy: hi)
        out += (out.isEmpty ? "" : " ") + text[a..<b]
      }
      i = j
    }
    return out.isEmpty ? nil : out
  }

  /// 두 쪽 인덱스 범위가 가리키는 시각을 합쳐 하나의 구간으로 만든다.
  private static func timeSpan(_ L: Flat, _ lr: Range<Int>,
                               _ W: Flat, _ wr: Range<Int>) -> (Double, Double) {
    var times: [Double] = []
    if lr.lowerBound < L.time.count { times.append(L.time[lr.lowerBound]) }
    if wr.lowerBound < W.time.count { times.append(W.time[wr.lowerBound]) }
    if let last = lr.last, last < L.time.count { times.append(L.time[last]) }
    if let last = wr.last, last < W.time.count { times.append(W.time[last]) }
    guard let lo = times.min(), let hi = times.max() else { return (0, 0) }
    return (lo, hi)
  }

  /// 화면·진단용 요약
  static func summary(_ blocks: [Block]) -> [String: Any] {
    var chars: [String: Int] = ["same": 0, "script": 0, "missing": 0, "differ": 0]
    for b in blocks {
      chars[b.kind.rawValue, default: 0] += max(b.live.count, b.whisper.count)
    }
    let total = chars.values.reduce(0, +)
    let diff = total - (chars["same"] ?? 0)
    return [
      "totalChars": total,
      "agreeChars": chars["same"] ?? 0,
      "agreeRatio": total > 0 ? Double(chars["same"] ?? 0) / Double(total) : 0,
      "script": chars["script"] ?? 0,
      "missing": chars["missing"] ?? 0,
      "differ": chars["differ"] ?? 0,
      "diffChars": diff,
      "blocks": blocks.count,
    ]
  }

  // MARK: - 두 글월이 얼마나 겹치는가

  /// 두 문자열의 **가장 긴 공통 부분문자열 길이**. 글자·숫자만 남겨 비교한다.
  ///
  /// 무음 의심 줄이 진짜인지 가리는 두 번째 신호로 쓴다. 실시간 전사기는 음성 활동
  /// 검출이 들어 있어 침묵을 침묵으로 두므로, **같은 시각에 실시간 기록이 있다는 것 자체가
  /// 그 자리에 말이 있었다는 증거**다.
  ///
  /// 비율이 아니라 **글자 수**로 재야 한다 — 실측에서 환각은 대부분 「감사합니다」(5자)라
  /// 우연히 2자만 겹쳐도 40%가 된다. 절대 길이로는 깨끗하게 갈렸다:
  /// ```
  /// 환각 5건:  0자, 1자, 2자, 2자, 0자
  /// 진짜 2건:  7자, 51자
  /// ```
  static func longestCommon(_ a: some StringProtocol, _ b: some StringProtocol) -> Int {
    let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
    let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    // 앞 행만 들고 도는 DP. 긴 강의 전체를 훑어도 메모리가 한 줄이면 된다.
    var previous = [Int](repeating: 0, count: y.count + 1)
    var current = previous
    var best = 0
    for i in 0..<x.count {
      for j in 0..<y.count {
        current[j + 1] = x[i] == y[j] ? previous[j] + 1 : 0
        if current[j + 1] > best { best = current[j + 1] }
      }
      swap(&previous, &current)
    }
    return best
  }

  // MARK: - 정확도 측정

  /// 글자 오류율(CER). 한국어는 띄어쓰기가 불안정해 단어 단위(WER)보다 이쪽이 맞다.
  static func characterErrorRate(reference: String, hypothesis: String) -> Double {
    let r = reference.filter { $0.isLetter || $0.isNumber }.lowercased().map { $0 }
    let h = hypothesis.filter { $0.isLetter || $0.isNumber }.lowercased().map { $0 }
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }

    var previous = Array(0...h.count)
    var current = previous
    for i in 1...r.count {
      current[0] = i
      for j in 1...h.count {
        current[j] = r[i - 1] == h[j - 1]
          ? previous[j - 1]
          : min(previous[j - 1], previous[j], current[j - 1]) + 1
      }
      swap(&previous, &current)
    }
    return Double(previous[h.count]) / Double(r.count)
  }
}

import Foundation
import PDFKit

// MARK: - mecab-ko 연동

/// Homebrew 로 설치한 한국어 형태소 분석기.
/// Apple 의 NaturalLanguage 는 한국어에 품사·원형 정보를 전혀 주지 않아서(전부 OtherWord)
/// 조사와 어미를 제대로 떼려면 이쪽이 필요하다. 없으면 내장 규칙으로 폴백한다.
enum MecabKo {
  private static let binaryCandidates = [
    "/opt/homebrew/bin/mecab", "/usr/local/bin/mecab", "/usr/bin/mecab",
  ]
  private static let dicCandidates = [
    "/opt/homebrew/lib/mecab/dic/mecab-ko-dic",
    "/usr/local/lib/mecab/dic/mecab-ko-dic",
  ]

  private static let cache: (binary: String?, dic: String?) = {
    let fm = FileManager.default
    let bin = binaryCandidates.first { fm.isExecutableFile(atPath: $0) }
    let dic = dicCandidates.first { fm.fileExists(atPath: $0 + "/sys.dic") }
    return (bin, dic)
  }()

  static var isAvailable: Bool { cache.binary != nil && cache.dic != nil }

  static var versionInfo: String {
    guard let bin = cache.binary else { return "미설치" }
    return "\(bin) + mecab-ko-dic"
  }

  /// 한 줄이 너무 길면 mecab 의 입력 버퍼(기본 8KB)를 넘긴다. 미리 잘라 둔다.
  private static func wrap(_ text: String, limit: Int = 1500) -> String {
    var out: [String] = []
    for line in text.components(separatedBy: .newlines) {
      if line.utf8.count <= limit { out.append(line); continue }
      var current = ""
      for word in line.split(separator: " ", omittingEmptySubsequences: false) {
        if current.utf8.count + word.utf8.count + 1 > limit {
          out.append(current)
          current = String(word)
        } else {
          current += (current.isEmpty ? "" : " ") + word
        }
      }
      if !current.isEmpty { out.append(current) }
    }
    return out.joined(separator: "\n")
  }

  struct Phrase {
    var tokens: [String]
    /// 마지막 명사 뒤에 하/되(XSV) 가 붙어 있었는지.
    /// "사용한다" 의 "사용" 처럼 단독으로는 용어가 아닌 동사 어간을 걸러내는 데 쓴다.
    var lastIsVerbStem: Bool
  }

  /// 명사(NNG/NNP/SL/SH)가 연달아 붙은 구간만 뽑아낸다.
  /// "푸리에/NNP 변환/NNG 의/JKG" → ["푸리에", "변환"]
  static func nounPhrases(_ text: String) -> [Phrase]? {
    guard let bin = cache.binary, let dic = cache.dic else { return nil }

    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("zoomcaption-mecab-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard (try? wrap(text).write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = ["-d", dic, tmp.path]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice

    do { try process.run() } catch { return nil }
    // 파일 입력이라 교착 없이 한 번에 읽어도 된다.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let dump = String(data: data, encoding: .utf8) else { return nil }

    var phrases: [Phrase] = []
    var current: [String] = []
    func flush(verbStem: Bool = false) {
      if !current.isEmpty {
        phrases.append(Phrase(tokens: current, lastIsVerbStem: verbStem))
        current = []
      }
    }

    for line in dump.split(separator: "\n", omittingEmptySubsequences: true) {
      if line == "EOS" { flush(); continue }
      let parts = line.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2 else { flush(); continue }
      let surface = String(parts[0])
      let pos = String(parts[1].split(separator: ",").first ?? "")

      // NNG 일반명사 / NNP 고유명사 / SL 외국어 / SH 한자
      if pos == "NNG" || pos == "NNP" || pos == "SL" || pos == "SH" {
        current.append(surface)
      } else {
        // XSV(하다/되다) · XSA 가 뒤따르면 앞 명사는 용언 어간이다. "사용/NNG + 한다/XSV+EF"
        flush(verbStem: pos.hasPrefix("XSV") || pos.hasPrefix("XSA"))
      }
    }
    flush()
    return phrases
  }
}

// MARK: - 교안 분석

/// 교안 PDF에서 과목 용어를 뽑아낸다.
/// 뽑은 용어는 (1) 음성 인식 힌트, (2) 요약 시 용어집으로 쓰인다.
enum DomainKnowledge {

  struct Result {
    var pages: Int
    var characters: Int
    var terms: [String]
    var text: String
    /// 텍스트 레이어가 없는 스캔 PDF 여부
    var looksScanned: Bool
    /// 어떤 분석기를 썼는지 (UI 표시용)
    var analyzer: String
    /// 머리말·꼬리말 블록으로 판단해 걸러낸 용어 (왜 빠졌는지 보여주기 위함)
    var droppedBoilerplate: [String] = []
  }

  enum DomainError: LocalizedError {
    case cannotOpen
    var errorDescription: String? { "PDF를 열 수 없습니다. 암호가 걸려 있거나 손상된 파일일 수 있습니다." }
  }

  /// SpeechAnalyzer 에 넘길 용어 개수 상한.
  /// 너무 많이 넣으면 인식이 오히려 흔들리므로 상위 빈도만 쓴다.
  static let maxContextualTerms = 150

  static func analyze(pdf data: Data, maxTerms: Int = maxContextualTerms) throws -> Result {
    guard let doc = PDFDocument(data: data) else { throw DomainError.cannotOpen }

    // 페이지별 텍스트가 필요하다. 어느 페이지에 나오는지가 곧 판단 근거다.
    var pageTexts: [String] = []
    pageTexts.reserveCapacity(doc.pageCount)
    for i in 0..<doc.pageCount { pageTexts.append(doc.page(at: i)?.string ?? "") }
    let text = pageTexts.joined(separator: "\n")
    let pages = doc.pageCount

    // 페이지당 평균 20자도 안 되면 텍스트 레이어가 없는 스캔본으로 본다.
    let scanned = pages > 0 && text.count < pages * 20
    guard !scanned else {
      return Result(pages: pages, characters: text.count, terms: [], text: text,
                    looksScanned: true, analyzer: "-")
    }

    let candidates: [String: Int]
    let analyzer: String
    if let phrases = MecabKo.nounPhrases(text) {
      candidates = candidateTerms(phrases: phrases)
      analyzer = "mecab-ko"
    } else {
      candidates = heuristicCandidates(text)
      analyzer = "내장 규칙"
    }

    let refined = refine(candidates: candidates, pageTexts: pageTexts, limit: maxTerms)
    return Result(pages: pages, characters: text.count, terms: refined.terms,
                  text: text, looksScanned: false, analyzer: analyzer,
                  droppedBoilerplate: refined.dropped)
  }

  // MARK: - 페이지 분포로 다듬기
  //
  // 실측(363쪽 Java 교안): 법적 고지 4개가 "정확히 같은 35쪽"에 나오고 문서 전체에 흩어져 있었다.
  // 반면 진짜 용어는 페이지 집합이 서로 다르고 대개 한 챕터에 뭉친다.
  // 그래서 (1) 같은 페이지 집합을 공유하는 덩어리 + (2) 문서 전체에 퍼짐 → 머리말·꼬리말로 본다.

  /// 같은 페이지 집합을 공유해야 블록으로 볼 최소 인원
  private static let boilerplateGroupSize = 3
  /// 문서의 이 비율 이상에 걸쳐 흩어져 있어야 블록으로 본다
  private static let boilerplateSpanRatio = 0.8
  /// 이 페이지 수 미만이면 블록 판정을 아예 하지 않는다.
  /// 슬라이드 몇 장이 반복되는 짧은 교안에서는 진짜 용어도 같은 페이지 집합을 공유해
  /// 통째로 걸러지는 사고가 난다 (실측: 12쪽 교안에서 용어 17개가 전부 삭제됨).
  private static let boilerplateMinPages = 30
  /// 머리말·꼬리말은 일부 페이지에만 흩어져 있다. 이 비율을 넘게 덮으면 본문으로 본다.
  private static let boilerplateMaxCoverage = 0.25
  /// 반대로 거의 모든 페이지에 나오면 그건 변별력이 없는 상용구다.
  private static let ubiquitousCoverage = 0.9

  /// 띄어쓰기가 교안과 mecab 사이에서 어긋나도 찾도록 공백을 지우고 비교한다.
  private static func squashed(_ s: String) -> String {
    s.replacingOccurrences(of: " ", with: "").lowercased()
  }

  /// 한 용어에서 파생된 부분 구절("데이터 웨어 하우스" → "데이터 웨어", "웨어 하우스")은
  /// 당연히 같은 페이지에 나온다. 이걸 서로 다른 용어로 세면 진짜 내용이 블록으로 오판된다.
  /// 서로 포함 관계가 아닌 것만 독립된 구성원으로 센다.
  private static func independentMembers(_ members: [String]) -> [String] {
    var roots: [String] = []
    for m in members.sorted(by: { $0.count > $1.count }) {
      let needle = squashed(m)
      if roots.contains(where: { squashed($0).contains(needle) }) { continue }
      roots.append(m)
    }
    return roots
  }

  private static func refine(candidates: [String: Int],
                             pageTexts: [String],
                             limit: Int) -> (terms: [String], dropped: [String]) {
    guard !pageTexts.isEmpty else {
      return (Array(candidates.sorted { $0.value > $1.value }.prefix(limit).map(\.key)), [])
    }
    let squashedPages = pageTexts.map(squashed)
    let total = pageTexts.count

    // 후보마다 등장 페이지 집합
    var pageSets: [String: [Int]] = [:]
    for term in candidates.keys {
      let needle = squashed(term)
      guard !needle.isEmpty else { continue }
      let hits = (0..<total).filter { squashedPages[$0].contains(needle) }
      if !hits.isEmpty { pageSets[term] = hits }
    }

    // 동일한 페이지 집합을 공유하는 덩어리 찾기
    var groups: [String: [String]] = [:]
    for (term, hits) in pageSets {
      groups[hits.map(String.init).joined(separator: ","), default: []].append(term)
    }
    var dropped: [String] = []

    // (a) 거의 모든 페이지에 나오는 말 — 변별력이 없다
    for (term, hits) in pageSets
    where Double(hits.count) / Double(total) >= ubiquitousCoverage && total >= boilerplateMinPages {
      dropped.append(term)
    }

    // (b) 같은 페이지 집합을 공유하면서 문서 전체에 흩어진 덩어리 — 머리말·꼬리말 블록
    if total >= boilerplateMinPages {
      for (signature, members) in groups {
        // 부분 구절끼리 뭉친 건 한 개로 센다
        guard independentMembers(members).count >= boilerplateGroupSize else { continue }
        let hits = signature.split(separator: ",").compactMap { Int($0) }
        guard let first = hits.first, let last = hits.last, hits.count > 1 else { continue }
        let span = Double(last - first + 1) / Double(total)
        let coverage = Double(hits.count) / Double(total)
        // 흩어져 있으면서도 덮는 페이지는 적어야 한다. 넓게 덮으면 그건 본문이다.
        if span >= boilerplateSpanRatio && coverage <= boilerplateMaxCoverage {
          dropped.append(contentsOf: members.sorted())
        }
      }
    }

    // 안전장치: 후보의 절반 넘게 지우려 하면 판정을 신뢰하지 않는다.
    if dropped.count * 2 > pageSets.count {
      logWarn("교안 용어 필터가 후보의 절반 넘게(\(dropped.count)/\(pageSets.count)) 지우려 해서 무시합니다.")
      dropped = []
    }
    let droppedSet = Set(dropped)

    // 점수는 "총 등장 횟수" 가 아니라 "몇 개 페이지에 걸쳐 나오는가".
    // 한 페이지에서 스무 번 반복되는 조각이 상위로 올라오는 걸 막는다.
    // 다만 페이지 수만 보면 아무 데나 나오는 짧은 낱말이 이기므로,
    // 여러 단어로 된 구체적인 용어에 가중치를 준다.
    func score(_ term: String, _ pages: Int) -> Int {
      let words = term.split(separator: " ").count
      return pages * (words >= 2 ? 3 : 1)
    }
    let ordered = pageSets
      .filter { !droppedSet.contains($0.key) }
      .sorted { a, b in
        let sa = score(a.key, a.value.count), sb = score(b.key, b.value.count)
        if sa != sb { return sa > sb }
        let wordsA = a.key.split(separator: " ").count, wordsB = b.key.split(separator: " ").count
        if wordsA != wordsB { return wordsA > wordsB }
        return a.key < b.key
      }
      .map(\.key)

    // 같은 말이 자리를 여러 개 차지하지 않게 한다.
    //  - 대소문자만 다른 중복: "Public class" / "public class"
    //  - 이미 뽑은 긴 용어의 부분 구절: "국소 수용장 개념" 이 있으면 "수용장 개념" 은 뺀다
    var picked: [String] = []
    var seen = Set<String>()
    for term in ordered {
      let key = squashed(term)
      if seen.contains(key) { continue }
      if picked.contains(where: { squashed($0).contains(key) }) { continue }
      seen.insert(key)
      picked.append(term)
      if picked.count >= limit { break }
    }

    return (picked, dropped)
  }

  private static let stopwords: Set<String> = [
    "그것", "이것", "저것", "우리", "여러분", "경우", "때문", "정도", "가지", "부분", "내용",
    "다음", "이번", "오늘", "설명", "이해", "사용", "가능", "필요", "문제", "결과", "생각",
    "방법", "관련", "각각", "모두", "여기", "저기", "그림", "표시", "페이지", "참고", "예시",
    "의미", "관계", "비교", "측정", "때", "수", "것", "등", "및", "장", "절", "쪽",
    "the", "and", "for", "with", "this", "that", "from", "are", "was", "not", "ch",
  ]

  /// 명사구 목록에서 후보와 원시 빈도를 뽑는다. 최종 순위는 refine 이 페이지 수로 정한다.
  private static func candidateTerms(phrases: [MecabKo.Phrase]) -> [String: Int] {
    var compound: [String: Int] = [:]
    var single: [String: Int] = [:]
    /// "사용한다" 처럼 하다/되다가 붙어 쓰인 적이 있는 명사. 단독 용어로는 뽑지 않는다.
    var verbStems = Set<String>()

    for phrase in phrases {
      // 한글·한자는 2자부터, 라틴 문자만으로 된 토큰은 3자부터 인정한다.
      // "io", "it", "of", "do", "OK" 같은 조각이 페이지마다 나와 상위를 차지하는 걸 막는다.
      let clean = phrase.tokens.filter { token in
        let isLatinOnly = token.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil
        return isLatinOnly ? token.count >= 3 : token.count >= 2
      }
      guard !clean.isEmpty else { continue }
      if phrase.lastIsVerbStem, let last = phrase.tokens.last { verbStems.insert(last) }

      if clean.count >= 2 {
        // 긴 구 전체와, 그 안의 2단어 조합을 함께 센다.
        let whole = clean.joined(separator: " ")
        if whole.count <= 30 { compound[whole, default: 0] += 1 }
        for i in 0..<(clean.count - 1) {
          compound["\(clean[i]) \(clean[i + 1])", default: 0] += 1
        }
      }
      for t in clean where !stopwords.contains(t.lowercased()) {
        single[t, default: 0] += 1
      }
    }

    let strong = compound.filter { $0.value >= 2 && !isAllStopwords($0.key) }
    var consumed = Set<String>()
    for (phrase, _) in strong {
      phrase.split(separator: " ").forEach { consumed.insert(String($0)) }
    }

    var out: [String: Int] = [:]
    for (phrase, count) in strong { out[phrase] = count * 3 }
    for (term, count) in single
    where count >= 3 && !consumed.contains(term) && !verbStems.contains(term) {
      out[term] = count
    }
    return out
  }

  private static func isAllStopwords(_ phrase: String) -> Bool {
    phrase.split(separator: " ").allSatisfy { stopwords.contains($0.lowercased()) }
  }

  // MARK: - 폴백: mecab-ko 가 없을 때의 규칙 기반 처리

  /// 명사 끝소리로는 거의 안 쓰이는 조사. 항상 떼도 안전하다. (긴 것부터)
  private static let safeParticles = [
    "으로부터", "에서부터", "에게서", "으로써", "으로서", "에서는", "에서의", "으로의",
    "이라고", "라고는", "이라는", "에게는", "과는", "와는", "과의", "와의",
    "으로", "에서", "에게", "한테", "께서", "부터", "까지", "보다", "처럼", "라고", "라는",
    "이나", "이란", "이라", "만큼", "조차", "마저", "밖에", "로의", "로써", "로서",
    "을", "를", "는",
  ]
  /// 명사 끝소리로도 흔한 조사("정의", "푸리에"…). 뗀 어간이 문서에서 독립적으로 쓰였을 때만 뗀다.
  private static let riskyParticles = ["이", "가", "은", "의", "에", "와", "과", "로", "도", "만", "랑", "께"]

  private static let verbEndings = [
    "습니다", "합니다", "됩니다", "입니다", "이다", "한다", "된다", "진다", "난다", "본다",
    "하는", "되는", "이는", "하고", "하며", "해서", "하여", "이며", "이고", "하자", "보자", "다",
  ]

  private struct Token { var stem: String; var hadParticle: Bool; var isVerb: Bool; var usable: Bool }

  private static func parse(_ raw: String, bareVocab: Set<String>?) -> Token {
    let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    let dead = Token(stem: word, hadParticle: false, isVerb: false, usable: false)
    guard word.count >= 2, word.rangeOfCharacter(from: .decimalDigits) == nil else { return dead }
    if word.count >= 3, verbEndings.contains(where: { word.hasSuffix($0) }) {
      return Token(stem: word, hadParticle: false, isVerb: true, usable: false)
    }

    // 안전한 조사는 무조건 뗀다. 첫 일치에서 결정하고 멈춰야
    // "합으로" 가 "으로" 제거 실패 후 "로" 로 잘못 떨어지는 걸 막는다.
    for p in safeParticles where word.hasSuffix(p) {
      let stem = String(word.dropLast(p.count))
      return stem.count >= 2
        ? Token(stem: stem, hadParticle: true, isVerb: false, usable: !stopwords.contains(stem.lowercased()))
        : Token(stem: word, hadParticle: false, isVerb: false, usable: !stopwords.contains(word.lowercased()))
    }
    // 위험한 조사는 어간이 문서 안에서 독립적으로 쓰인 적이 있을 때만 뗀다.
    // ("변환의" → "변환" ○ / "푸리에" → "푸리" ✗)
    if let vocab = bareVocab {
      for p in riskyParticles where word.hasSuffix(p) {
        let stem = String(word.dropLast(p.count))
        if stem.count >= 2, vocab.contains(stem) {
          return Token(stem: stem, hadParticle: true, isVerb: false,
                       usable: !stopwords.contains(stem.lowercased()))
        }
        break
      }
    }
    return Token(stem: word, hadParticle: false, isVerb: false, usable: !stopwords.contains(word.lowercased()))
  }

  private static let breakers = CharacterSet(charactersIn: ".!?;:,•·▪◦○●■□\n\r\t()[]{}<>「」『』\"'")

  static func heuristicCandidates(_ text: String) -> [String: Int] {
    guard !text.isEmpty else { return [:] }

    // 1차: 안전한 조사만 떼서 "독립적으로 쓰이는 명사" 목록을 만든다.
    var bareVocab = Set<String>()
    for sentence in text.components(separatedBy: breakers) {
      for raw in sentence.split(separator: " ") {
        let t = parse(String(raw), bareVocab: nil)
        if t.usable { bareVocab.insert(t.stem) }
      }
    }

    // 2차: 그 목록을 근거로 위험한 조사까지 처리하면서 용어를 센다.
    var unigrams: [String: Int] = [:]
    var bigrams: [String: Int] = [:]
    for sentence in text.components(separatedBy: breakers) {
      let tokens = sentence.split(separator: " ").map { parse(String($0), bareVocab: bareVocab) }
      for (i, t) in tokens.enumerated() {
        guard t.usable else { continue }
        unigrams[t.stem, default: 0] += 1
        // 복합어는 앞 단어에 조사가 붙어 있지 않을 때만 성립한다.
        guard i + 1 < tokens.count, !t.hadParticle else { continue }
        let next = tokens[i + 1]
        guard next.usable, !next.isVerb else { continue }
        bigrams["\(t.stem) \(next.stem)", default: 0] += 1
      }
    }

    let strong = bigrams.filter { $0.value >= 2 && !isAllStopwords($0.key) }
    var consumed = Set<String>()
    for (phrase, _) in strong { phrase.split(separator: " ").forEach { consumed.insert(String($0)) } }

    var out: [String: Int] = [:]
    for (phrase, count) in strong { out[phrase] = count * 3 }
    for (term, count) in unigrams where count >= 3 && !consumed.contains(term) { out[term] = count }
    return out
  }

  /// 요약 프롬프트에 끼워 넣을 용어집. 컨텍스트가 좁으므로 짧게 유지한다.
  static func glossary(_ terms: [String], limit: Int = 40) -> String {
    guard !terms.isEmpty else { return "" }
    return terms.prefix(limit).joined(separator: ", ")
  }
}

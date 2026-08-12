import Foundation
import FoundationModels

/// 어떤 요약 엔진을 쓸 수 있는지. 전부 기기 안에서 돈다.
enum SummaryEngine: Sendable, Equatable {
  /// 로컬 Ollama 모델. 품질이 가장 좋다.
  case ollama(String)
  /// Apple Intelligence 내장 모델. 컨텍스트 4K라 긴 강의는 쪼개야 한다.
  case apple
  /// 모델 없이 도는 빈도 기반 추출.
  case extractive(reason: String)

  var label: String {
    switch self {
    case .ollama(let m): return "Ollama · \(m)"
    case .apple: return "Apple Intelligence"
    case .extractive: return "추출식"
    }
  }

  /// UI에 띄울 안내. 최선이 아닐 때만 내용이 있다.
  var note: String? {
    switch self {
    case .ollama:
      return nil
    case .apple:
      return "Apple 내장 모델로 요약합니다. Ollama에 한국어 모델을 설치하면 "
           + "긴 강의를 쪼개지 않고 한 번에 요약해 정확도가 크게 올라갑니다 (setup.sh 참고)."
    case .extractive(let reason):
      return "\(reason) 지금은 원문 문장을 그대로 뽑는 추출식 요약을 씁니다."
    }
  }
}

/// 온디바이스 요약기. Ollama → Apple Intelligence → 추출식 순으로 내려간다.
enum Summarizer {

  /// 지금 쓸 수 있는 최선의 엔진.
  /// 서버가 꺼져 있어도 디스크에 모델이 있으면 Ollama 로 친다 — 요약할 때 알아서 띄운다.
  static func currentEngine() async -> SummaryEngine {
    if let installed = await OllamaClient.installedModels(),
       let model = OllamaClient.pickModel(from: installed) {
      return .ollama(model)
    }
    if OllamaClient.binaryPath != nil,
       let model = OllamaClient.pickModel(from: OllamaClient.installedModelsOffline()) {
      return .ollama(model)
    }
    switch SystemLanguageModel.default.availability {
    case .available:
      return .apple
    case .unavailable(let reason):
      let why: String
      switch reason {
      case .appleIntelligenceNotEnabled:
        why = "Ollama 모델이 없고 Apple Intelligence도 꺼져 있습니다."
      case .deviceNotEligible:
        why = "Ollama 모델이 없고 이 기기는 Apple Intelligence를 지원하지 않습니다."
      case .modelNotReady:
        why = "Ollama 모델이 없고 Apple Intelligence 모델이 아직 준비 중입니다."
      @unknown default:
        why = "쓸 수 있는 언어 모델이 없습니다."
      }
      return .extractive(reason: why)
    @unknown default:
      return .extractive(reason: "쓸 수 있는 언어 모델이 없습니다.")
    }
  }

  /// - Parameter onProgress: (완료 단계, 전체 단계)
  static func summarize(transcript: String,
                        title: String,
                        glossary: String = "",
                        onProgress: @escaping @Sendable (Int, Int) -> Void) async -> String {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "_기록이 비어 있어 요약할 내용이 없습니다._" }

    let engine = await currentEngine()

    switch engine {
    case .ollama(let model):
      onProgress(0, 1)
      // 꺼져 있으면 여기서 띄운다. 요약이 끝나면 모델은 keep_alive:0 으로 바로 내려간다.
      guard await OllamaClient.ensureServer() else {
        return await appleOrExtractive(text: text, title: title, glossary: glossary,
                                       onProgress: onProgress,
                                       prefixNote: "Ollama 서버를 띄우지 못해 내장 모델로 대체했습니다.")
      }
      do {
        // 컨텍스트가 넉넉해서 녹취 전체를 한 번에 넣는다. 쪼개지 않으니 앞뒤가 이어진다.
        let note = try await OllamaClient.summarize(
          transcript: text, title: title, glossary: glossary, model: model)
        onProgress(1, 1)
        return render(note)
      } catch {
        // Ollama가 죽었거나 모델이 응답을 못 하면 Apple 내장 모델로 내려간다.
        return await appleOrExtractive(text: text, title: title, glossary: glossary,
                                       onProgress: onProgress,
                                       prefixNote: "Ollama 요약 실패(\(error.localizedDescription)) — 내장 모델로 대체했습니다.")
      }

    case .apple:
      return await appleOrExtractive(text: text, title: title, glossary: glossary,
                                     onProgress: onProgress, prefixNote: nil)

    case .extractive(let reason):
      onProgress(1, 1)
      return extractiveSummary(text) + "\n\n---\n\n> \(reason)"
    }
  }

  private static func appleOrExtractive(text: String, title: String, glossary: String,
                                        onProgress: @escaping @Sendable (Int, Int) -> Void,
                                        prefixNote: String?) async -> String {
    guard case .available = SystemLanguageModel.default.availability else {
      onProgress(1, 1)
      return extractiveSummary(text)
        + "\n\n---\n\n> \(prefixNote ?? "쓸 수 있는 언어 모델이 없어 추출식 요약을 썼습니다.")"
    }
    do {
      let body = try await modelSummary(text: text, title: title, glossary: glossary, onProgress: onProgress)
      return prefixNote.map { "\(body)\n\n---\n\n> \($0)" } ?? body
    } catch {
      return extractiveSummary(text)
        + "\n\n---\n\n> 모델 요약 중 오류가 나서 추출식 요약으로 대체했습니다: \(error.localizedDescription)"
    }
  }

  // MARK: - 생성 스키마
  //
  // 자유 형식으로 "이런 형식으로 써줘" 라고 부탁하면 모델이 멋대로 섹션을 만들거나
  // 한 줄 요약을 빼먹는다. 스키마를 주면 디코딩 단계에서 구조가 강제된다.
  //
  // @Generable 매크로 대신 DynamicGenerationSchema 를 쓴다. 매크로 플러그인은
  // 전체 Xcode 에만 들어 있어서, Command Line Tools 만으로 빌드하려면 이쪽이어야 한다.

  private static func stringField(_ description: String) -> DynamicGenerationSchema.Property {
    .init(name: "", description: description, schema: .init(type: String.self))
  }

  /// 구간별 메모: 핵심 내용 + 공지
  private static let chunkSchema: GenerationSchema? = {
    let root = DynamicGenerationSchema(
      name: "ChunkNote",
      description: "녹취 한 구간에서 뽑아낸 메모",
      properties: [
        .init(name: "points",
              description: "이 구간에서 실제로 설명한 내용. 한 문장씩. 인사말·잡담·음향 확인은 제외",
              schema: .init(arrayOf: .init(type: String.self), minimumElements: 1, maximumElements: 5)),
        .init(name: "announcements",
              description: "휴강·보강·시험·과제·제출기한·교재 범위 같은 공지. 날짜와 조건을 그대로 옮길 것. 없으면 빈 배열",
              schema: .init(arrayOf: .init(type: String.self), minimumElements: 0, maximumElements: 4)),
      ])
    return try? GenerationSchema(root: root, dependencies: [])
  }()

  /// 최종 노트: 한 줄 요약 + 주요 내용 + 핵심 용어
  private static let coreSchema: GenerationSchema? = {
    let term = DynamicGenerationSchema(
      name: "Term",
      description: "수업에서 설명한 전문 용어 하나",
      properties: [
        .init(name: "term", description: "용어 이름만. 문장이 아니라 명사구",
              schema: .init(type: String.self)),
        .init(name: "meaning",
              description: "메모에 적힌 설명만 써서 한 문장으로. 메모에 없는 지식을 끌어오지 말 것",
              schema: .init(type: String.self)),
      ])
    let root = DynamicGenerationSchema(
      name: "LectureCore",
      description: "수업 복습 노트",
      properties: [
        .init(name: "oneLine", description: "이 수업이 무엇을 다뤘는지 한 문장으로",
              schema: .init(type: String.self)),
        .init(name: "keyPoints",
              description: "논리 순서대로 정리한 핵심 내용. 각 항목은 한 문장",
              schema: .init(arrayOf: .init(type: String.self), minimumElements: 4, maximumElements: 8)),
        .init(name: "terms", description: "수업에서 설명한 전문 용어",
              schema: .init(arrayOf: .init(referenceTo: "Term"), minimumElements: 0, maximumElements: 6)),
      ])
    return try? GenerationSchema(root: root, dependencies: [term])
  }()

  struct TermDefinition: Sendable { var term: String; var meaning: String }

  /// 어떤 엔진을 쓰든 결국 이 모양으로 모인다. 마크다운은 render(_:) 가 찍는다.
  struct LectureNote: Sendable {
    var oneLine: String
    var keyPoints: [String]
    var terms: [TermDefinition]
    var announcements: [String]
  }

  enum SummarizerError: LocalizedError {
    case schemaUnavailable
    var errorDescription: String? { "요약 스키마를 만들 수 없습니다." }
  }

  // MARK: - FoundationModels 경로 (map-reduce)

  private static let chunkSize = 1600      // 문자 기준. 컨텍스트 4K 토큰을 넘지 않도록 보수적으로 잡음
  private static let reduceSize = 2400

  private static func modelSummary(text: String,
                                   title: String,
                                   glossary: String,
                                   onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> String {
    let chunks = split(text, limit: chunkSize)
    let total = chunks.count + 1

    // 교안에서 뽑은 용어를 알려주면 인식 오탈자를 올바른 용어로 되돌려 준다.
    let glossaryHint = glossary.isEmpty ? "" : """

      이 수업 교안의 용어다. 녹취에 비슷하게 들리는 오탈자가 있으면 이 용어로 바로잡아라:
      \(glossary)
      """
    let mapInstructions = """
      너는 대학 수업 녹취를 정리하는 조교다. 한국어로만 답한다.
      녹취는 음성 인식 결과라 오탈자와 구어체 군더더기가 많다. 문맥으로 보정해서 읽고,
      "어", "자", "음" 같은 군더더기와 인사말·음향 확인은 버려라.
      녹취에 없는 내용을 지어내지 마라.\(glossaryHint)
      """

    guard let chunkSchema, let coreSchema else { throw SummarizerError.schemaUnavailable }

    var points: [String] = []
    var announcements: [String] = []

    // map: 구간별로 핵심 내용과 공지를 따로 뽑는다.
    for (i, chunk) in chunks.enumerated() {
      let session = LanguageModelSession(instructions: mapInstructions)
      let reply = try await session.respond(
        to: """
          다음은 「\(title)」 녹취의 \(i + 1)/\(chunks.count) 구간이다.

          ---
          \(chunk)
          ---
          """,
        schema: chunkSchema)
      let content = reply.content
      points.append(contentsOf: (try? content.value([String].self, forProperty: "points")) ?? [])
      announcements.append(contentsOf: (try? content.value([String].self, forProperty: "announcements")) ?? [])
      onProgress(i + 1, total)
    }

    // 공지는 날짜·기한이 생명이라 재요약을 거치지 않고 그대로 들고 간다.
    // (한 번 더 요약하면 "다음 주 금요일 자정" 같은 게 사라진다)
    let finalAnnouncements = dedupe(announcements)

    // reduce: 핵심 내용을 하나의 노트로 합친다. 스키마가 형식을 보장한다.
    var merged = points.map { "- \($0)" }.joined(separator: "\n")
    if merged.count > reduceSize {
      merged = String(merged.prefix(reduceSize))
    }
    let finalSession = LanguageModelSession(instructions: """
      너는 대학 수업 복습 노트를 만드는 조교다. 한국어로만 답한다.
      제공된 메모에 있는 내용만 쓴다. 중복은 합치고, 구어체는 문어체로 다듬어라.
      핵심 용어의 설명은 주요 내용 문장을 그대로 복사하지 말고 정의답게 새로 써라.\(glossaryHint)
      """)
    let reply = try await finalSession.respond(
      to: """
        아래는 「\(title)」 수업의 구간별 메모다. 이걸로 복습 노트를 만들어라.

        ---
        \(merged)
        ---
        """,
      schema: coreSchema)

    let content = reply.content
    let note = LectureNote(
      oneLine: (try? content.value(String.self, forProperty: "oneLine")) ?? "",
      keyPoints: (try? content.value([String].self, forProperty: "keyPoints")) ?? points,
      terms: ((try? content.value([GeneratedContent].self, forProperty: "terms")) ?? []).compactMap { item in
        guard let t = try? item.value(String.self, forProperty: "term"),
              let m = try? item.value(String.self, forProperty: "meaning") else { return nil }
        return TermDefinition(term: t, meaning: m)
      },
      announcements: finalAnnouncements)

    onProgress(total, total)
    return render(note)
  }

  /// 스키마로 받은 결과를 마크다운으로 찍는다. 형식은 모델이 아니라 여기서 결정된다.
  static func render(_ note: LectureNote) -> String {
    let oneLine = note.oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
    var out = oneLine.isEmpty ? "" : "## 한 줄 요약\n\n\(oneLine)\n\n"

    out += "## 주요 내용\n\n"
    out += dedupe(note.keyPoints)
      .map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
      .joined(separator: "\n")
    out += "\n\n"

    let terms = dedupeTerms(note.terms)
    if !terms.isEmpty {
      out += "## 핵심 용어\n\n"
      out += terms
        .map { "- **\($0.term.trimmingCharacters(in: .whitespaces))** — \($0.meaning.trimmingCharacters(in: .whitespaces))" }
        .joined(separator: "\n")
      out += "\n\n"
    }

    out += "## 과제 · 공지\n\n"
    out += dedupe(note.announcements).isEmpty
      ? "언급 없음"
      : dedupe(note.announcements).map { "- \($0)" }.joined(separator: "\n")
    return out + "\n"
  }

  /// 같은 용어가 여러 번 나오면 하나만 남긴다.
  /// 모델이 "렐루" 와 "렐루 함수" 처럼 사실상 같은 걸 두 번 뱉는 일이 있어
  /// 이름뿐 아니라 설명이 겹치는 경우도 걸러낸다.
  static func dedupeTerms(_ terms: [TermDefinition]) -> [TermDefinition] {
    func norm(_ s: String) -> String {
      s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    var seenTerms = Set<String>()
    var seenMeanings = Set<String>()
    var out: [TermDefinition] = []

    for t in terms {
      let name = t.term.trimmingCharacters(in: .whitespacesAndNewlines)
      let meaning = t.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !meaning.isEmpty else { continue }

      let nameKey = norm(name)
      let meaningKey = norm(meaning)
      guard !nameKey.isEmpty else { continue }

      // 이미 나온 용어이거나, 다른 용어가 같은 설명을 이미 차지했으면 건너뛴다.
      if seenTerms.contains(nameKey) || seenMeanings.contains(meaningKey) { continue }
      // "렐루" 를 이미 넣었는데 "렐루 함수" 가 또 오는 경우 (혹은 그 반대)
      if seenTerms.contains(where: { $0.hasPrefix(nameKey) || nameKey.hasPrefix($0) }) { continue }
      // 이름은 달라도 설명이 사실상 같은 경우
      let grams = bigrams(meaning)
      if out.contains(where: { similarity(bigrams($0.meaning), grams) >= 0.7 }) { continue }

      seenTerms.insert(nameKey)
      seenMeanings.insert(meaningKey)
      out.append(TermDefinition(term: name, meaning: meaning))
    }
    return out
  }

  /// 정규화한 문자열의 2-gram 집합. 한국어는 형태소 없이도 이 정도면 유사도가 잘 잡힌다.
  private static func bigrams(_ s: String) -> Set<String> {
    let chars = Array(s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
    guard chars.count >= 2 else { return Set(chars.map(String.init)) }
    return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
  }

  /// 자카드 유사도
  private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    let union = a.union(b).count
    return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
  }

  /// 같은 내용이면 하나만 남긴다.
  /// 완전 일치뿐 아니라 "과제는 금요일까지입니다" / "과제 제출 기한은 금요일입니다" 처럼
  /// 표현만 바꾼 반복도 걸러낸다.
  static func dedupe(_ items: [String], threshold: Double = 0.55) -> [String] {
    var kept: [(text: String, grams: Set<String>)] = []
    for raw in items {
      let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !item.isEmpty else { continue }
      let grams = bigrams(item)
      if kept.contains(where: { similarity($0.grams, grams) >= threshold }) { continue }
      kept.append((item, grams))
    }
    return kept.map(\.text)
  }

  /// 문장 경계를 존중하며 자른다.
  private static func split(_ text: String, limit: Int) -> [String] {
    var chunks: [String] = []
    var current = ""
    for line in text.components(separatedBy: .newlines) {
      if current.count + line.count + 1 > limit, !current.isEmpty {
        chunks.append(current)
        current = ""
      }
      // 한 줄 자체가 한도를 넘으면 강제로 쪼갠다
      if line.count > limit {
        var rest = Substring(line)
        while rest.count > limit {
          let idx = rest.index(rest.startIndex, offsetBy: limit)
          chunks.append(String(rest[..<idx]))
          rest = rest[idx...]
        }
        current = String(rest)
      } else {
        current += (current.isEmpty ? "" : "\n") + line
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks.isEmpty ? [text] : chunks
  }

  // MARK: - 폴백: 추출식 요약

  private static let stopwords: Set<String> = [
    "그리고", "그래서", "하지만", "그런데", "이제", "우리", "저희", "여러분", "그거", "이거",
    "것이", "것을", "그것", "이것", "때문", "정도", "경우", "가지", "하는", "있는", "되는",
    "합니다", "입니다", "있습니다", "됩니다", "말씀", "생각", "얘기", "이야기", "부분", "내용",
  ]

  /// 모델 없이 도는 빈도 기반 추출 요약. 원문 문장을 그대로 뽑으므로 왜곡이 없다.
  static func extractiveSummary(_ text: String) -> String {
    let sentences = splitSentences(text)
    guard sentences.count > 3 else {
      return "## 요약\n\n" + sentences.map { "- \($0)" }.joined(separator: "\n")
    }

    // 단어 빈도
    var freq: [String: Int] = [:]
    for s in sentences {
      for w in tokens(s) { freq[w, default: 0] += 1 }
    }

    // 문장 점수 = 평균 단어 빈도 (길이 보정)
    let scored = sentences.enumerated().map { idx, s -> (Int, String, Double) in
      let ws = tokens(s)
      guard !ws.isEmpty else { return (idx, s, 0) }
      let score = ws.reduce(0.0) { $0 + Double(freq[$1] ?? 0) } / Double(ws.count)
      let lengthBonus = min(Double(s.count) / 40.0, 1.5)
      return (idx, s, score * lengthBonus)
    }

    let keep = max(5, min(14, sentences.count / 6))
    let picked = scored.sorted { $0.2 > $1.2 }.prefix(keep).sorted { $0.0 < $1.0 }

    return "## 주요 내용 (자동 추출)\n\n"
      + picked.map { "- \($0.1)" }.joined(separator: "\n")
  }

  private static func splitSentences(_ text: String) -> [String] {
    var result: [String] = []
    for rawLine in text.components(separatedBy: .newlines) {
      // "[00:01:23] 강의: " 접두어 제거
      var line = rawLine
      if let r = line.range(of: #"^\[\d{2}:\d{2}:\d{2}\]\s*\S+:\s*"#, options: .regularExpression) {
        line.removeSubrange(r)
      }
      let parts = line.replacingOccurrences(of: #"([.!?。]|다\.|요\.)\s+"#,
                                            with: "$1\n",
                                            options: .regularExpression)
        .components(separatedBy: .newlines)
      for p in parts {
        let t = p.trimmingCharacters(in: .whitespaces)
        if t.count >= 10 { result.append(t) }
      }
    }
    return result
  }

  private static func tokens(_ s: String) -> [String] {
    s.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "가-힣")))
      .flatMap { $0.components(separatedBy: .whitespaces) }
      .map { $0.trimmingCharacters(in: .punctuationCharacters) }
      .filter { $0.count >= 2 && !stopwords.contains($0) }
  }
}

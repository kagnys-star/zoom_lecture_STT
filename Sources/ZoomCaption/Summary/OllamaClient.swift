import Foundation

/// 로컬에서 도는 Ollama 서버에 붙는다.
///
/// Apple 내장 모델(~3B, 컨텍스트 4K)은 한국어 전문 용어에서 환각이 잦고,
/// 4K 제약 때문에 긴 강의를 쪼개 요약할 수밖에 없어 앞뒤가 끊긴다.
/// qwen3:8b 급이면 88분 강의(약 12,000토큰)를 한 번에 넣고 85초에 정리한다.
enum OllamaClient {
  static let host = "http://127.0.0.1:11434"

  /// 한국어 요약 품질 순 선호 목록. 설치된 것 중 앞에 있는 걸 고른다.
  static let preferredModels = [
    "qwen3:8b", "qwen3:14b", "exaone3.5:7.8b", "gemma3:12b", "qwen2.5:7b", "gemma3:4b", "qwen3:4b",
  ]

  /// 한국어 실측: 15,300자 → 11,806토큰. 여유를 둬서 1자 = 0.85토큰으로 잡는다.
  static let tokensPerChar = 0.85
  static let maxContext = 32_768

  enum OllamaError: LocalizedError {
    case notRunning
    case noModel
    case badResponse(String)

    var errorDescription: String? {
      switch self {
      case .notRunning:
        return "Ollama 서버가 떠 있지 않습니다. 터미널에서 `ollama serve` 를 실행하세요."
      case .noModel:
        return "쓸 수 있는 모델이 없습니다. `ollama pull qwen3:8b` 로 내려받으세요."
      case .badResponse(let s):
        return "Ollama 응답을 해석할 수 없습니다: \(s)"
      }
    }
  }

  // MARK: - 서버 수명 관리
  //
  // 메모리를 먹는 건 서버가 아니라 "적재된 모델" 이다. 실측:
  //   ollama 서버 프로세스   28MB
  //   llama-server(모델 적재) 5,825MB
  // 그래서 요약할 때만 모델을 올리고 끝나면 바로 내린다(keep_alive: 0).
  // 다시 올리는 데 1.7초밖에 안 걸려서 상주시킬 이유가 없다.

  private static let serverLock = NSLock()
  nonisolated(unsafe) private static var spawnedServer: Process?

  private static let binaryCandidates = [
    "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama",
  ]

  static var binaryPath: String? {
    binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// 서버가 떠 있는지만 본다. 띄우지는 않는다.
  static func isServerUp() async -> Bool {
    await installedModels() != nil
  }

  /// 서버 없이 디스크에서 설치된 모델을 찾는다.
  /// ~/.ollama/models/manifests/registry.ollama.ai/library/<모델>/<태그>
  static func installedModelsOffline() -> [String] {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
      .appendingPathComponent(".ollama/models/manifests/registry.ollama.ai/library", isDirectory: true)
    guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
    return names.flatMap { name -> [String] in
      let tags = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)) ?? []
      return tags.filter { !$0.hasPrefix(".") }.map { "\(name):\($0)" }
    }
  }

  /// 서버가 없으면 띄운다. 우리가 띄운 건 앱 종료 때 같이 내린다.
  @discardableResult
  static func ensureServer() async -> Bool {
    if await isServerUp() { return true }
    guard let bin = binaryPath else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = ["serve"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    serverLock.withLock { spawnedServer = process }

    // 뜰 때까지 기다린다 (보통 1초 안쪽)
    for _ in 0..<40 {
      try? await Task.sleep(for: .milliseconds(300))
      if await isServerUp() { return true }
    }
    return false
  }

  /// 우리가 띄운 서버만 내린다. 사용자가 직접 띄워둔 건 건드리지 않는다.
  static func shutdownSpawnedServer() {
    let process = serverLock.withLock { () -> Process? in
      let p = spawnedServer
      spawnedServer = nil
      return p
    }
    guard let process, process.isRunning else { return }
    process.terminate()
  }

  /// 설치된 모델 목록. 서버가 없으면 nil.
  static func installedModels() async -> [String]? {
    guard let url = URL(string: "\(host)/api/tags") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 3
    guard let (data, response) = try? await URLSession.shared.data(for: req),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["models"] as? [[String: Any]]
    else { return nil }
    return models.compactMap { $0["name"] as? String }
  }

  /// 쓸 모델을 고른다. 선호 목록에 없으면 설치된 아무거나 첫 번째.
  static func pickModel(from installed: [String]) -> String? {
    for candidate in preferredModels where installed.contains(candidate) { return candidate }
    // "qwen3:8b-q4_K_M" 처럼 태그가 다를 수 있으니 접두사로도 찾아본다.
    for candidate in preferredModels {
      let base = candidate.split(separator: ":").first.map(String.init) ?? candidate
      if let hit = installed.first(where: { $0.hasPrefix(base) }) { return hit }
    }
    return installed.first
  }

  // MARK: - 요약

  private static let systemPrompt = """
    너는 대학 수업 녹취를 정리하는 조교다. 한국어로만 답한다.

    규칙:
    - 녹취에 실제로 나온 내용만 쓴다. 네가 아는 지식을 끌어오지 마라.
    - 녹취는 음성 인식 결과라 오탈자가 있다. 문맥으로 보정해서 읽되 내용을 바꾸지는 마라.
    - "어", "자", "음" 같은 군더더기와 인사말, 음향 확인은 버린다.
    - oneLine: 주제를 나열하지 말고, 이 수업이 무엇을 다뤘는지 한 문장으로.
    - terms: 녹취에 나온 설명만으로 정의를 쓴다.
      meaning 은 40자 안팎으로 짧게 쓰고, 용어 이름을 다시 말하지 말고 바로 정의부터 써라.
      좋은 예 — term: "스트라이드", meaning: "필터가 움직이는 간격"
      나쁜 예 — term: "스트라이드", meaning: "스트라이드는 필터가 움직이는 간격으로 출력 크기를 줄인다"
      한 용어에 여러 개념을 몰아넣지 마라.
    - keyPoints: 수업 흐름 순서대로. 앞부분에 몰리지 말고 끝까지 고르게 담아라.
      공지·과제는 여기 넣지 마라. announcements 에만 쓴다.
      같은 내용을 표현만 바꿔 되풀이하지 마라. 다룬 내용이 적으면 항목도 적게 써라.
      억지로 개수를 채우지 마라.
    - announcements: 휴강·보강·시험·과제·제출기한·교재 범위. 날짜와 조건을 그대로 옮겨라.
    """

  // terms 를 keyPoints 앞에 두면(= 복사할 문장이 아직 없게 하면) 복붙이 사라지지만,
  // A/B 결과 프롬프트의 좋은 예/나쁜 예만으로도 복붙이 0이 되고 이 순서가 35초 더 빨랐다.
  // maxLength 는 llama.cpp 문법 변환에서 실제로 강제되는지 확인하지 못했다. 프롬프트가 실질적인 제약이다.
  private static let schema: [String: Any] = [
    "type": "object",
    "properties": [
      "oneLine": ["type": "string"],
      // minItems 를 높게 잡으면 내용이 적을 때 모델이 개수를 채우려고
      // 같은 말을 표현만 바꿔 반복한다. 하한을 풀고 프롬프트로 조절한다.
      "keyPoints": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 12],
      "terms": [
        "type": "array",
        "items": [
          "type": "object",
          "properties": [
            "term": ["type": "string"],
            "meaning": ["type": "string", "maxLength": 60],
          ],
          "required": ["term", "meaning"],
        ],
        "maxItems": 8,
      ],
      "announcements": ["type": "array", "items": ["type": "string"]],
    ],
    "required": ["oneLine", "keyPoints", "terms", "announcements"],
  ]

  static func summarize(transcript: String,
                        title: String,
                        glossary: String,
                        model: String) async throws -> Summarizer.LectureNote {
    let glossaryHint = glossary.isEmpty ? "" : """


      이 수업 교안의 용어다. 녹취에 비슷하게 들리는 오탈자가 있으면 이 용어로 바로잡아라:
      \(glossary)
      """

    // 녹취 전체가 컨텍스트에 들어가도록 num_ctx 를 잡는다. (기본값 4096이라 반드시 지정해야 한다)
    let estimated = Int(Double(transcript.count) * tokensPerChar) + 1200
    let numCtx = min(maxContext, max(8192, estimated + 1024))

    let body: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": systemPrompt + glossaryHint],
        ["role": "user", "content": "다음은 「\(title)」 녹취다. 이걸로 복습 노트를 만들어라.\n\n---\n\(transcript)\n---"],
      ],
      "stream": false,
      "format": schema,
      "think": false,          // qwen3 계열의 사고 과정 출력을 끈다
      // 요약이 끝나면 모델(약 5.8GB)을 즉시 메모리에서 내린다.
      // 기본값은 5분 상주. 재적재가 1.7초라 붙들고 있을 이유가 없다.
      "keep_alive": 0,
      // Ollama 문서가 구조화 출력에 temperature 0 을 권장한다.
      // 실제로 0.2 에서는 실행마다 공지 항목이 빠지거나 달라졌다.
      "options": ["temperature": 0, "num_ctx": numCtx],
    ]

    guard let url = URL(string: "\(host)/api/chat") else { throw OllamaError.notRunning }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 900   // 3시간짜리 강의도 견디도록 넉넉히

    log("Ollama 요약 요청 — 모델 \(model), 입력 \(transcript.count)자, "
      + "추정 \(estimated)토큰, num_ctx \(numCtx)"
      + (estimated > maxContext ? "  ⚠️ 컨텍스트 한계 초과 — 앞부분이 잘릴 수 있음" : ""))
    let startedAt = Date()
    let (data, response) = try await URLSession.shared.data(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw OllamaError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "?")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = root["message"] as? [String: Any],
          let content = message["content"] as? String,
          let parsed = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    else { throw OllamaError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "?") }

    let terms = (parsed["terms"] as? [[String: Any]] ?? []).compactMap { item -> Summarizer.TermDefinition? in
      guard let t = item["term"] as? String, let m = item["meaning"] as? String,
            !t.isEmpty, !m.isEmpty else { return nil }
      return Summarizer.TermDefinition(term: t, meaning: m)
    }
    let keyPoints = (parsed["keyPoints"] as? [String] ?? []).filter { !$0.isEmpty }
    let announcements = (parsed["announcements"] as? [String] ?? []).filter { !$0.isEmpty }
    log("Ollama 요약 완료 — \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))초, "
      + "주요내용 \(keyPoints.count) · 용어 \(terms.count) · 공지 \(announcements.count)")
    if keyPoints.isEmpty { logWarn("요약 결과의 주요 내용이 비어 있습니다. 입력이 너무 짧거나 잘렸을 수 있습니다.") }

    return Summarizer.LectureNote(
      oneLine: parsed["oneLine"] as? String ?? "",
      keyPoints: keyPoints,
      terms: terms,
      announcements: announcements)
  }

  // MARK: - 교안 용어 정제
  //
  // 규칙만으로는 슬라이드에 적힌 코드 조각("public static void main")을 걸러낼 수 없다.
  // 언어별 예약어 목록을 박아 넣으면 다음 학기 교재가 파이썬이면 무용지물이라,
  // "교수가 입으로 말할 용어인가" 라는 판단은 모델에게 맡긴다.

  private static let termFilterSchema: [String: Any] = [
    "type": "object",
    "properties": ["terms": ["type": "array", "items": ["type": "string"]]],
    "required": ["terms"],
  ]

  /// 후보 중 강의에서 실제로 말할 용어만 남긴다. 실패하면 nil (규칙 결과를 그대로 쓴다).
  static func filterLectureTerms(_ candidates: [String], model: String) async -> [String]? {
    guard candidates.count >= 10 else { return nil }

    let system = """
      너는 강의 교안에서 뽑은 후보 목록을 다듬는 조교다.
      교수가 강의 중 \u{201C}입으로 말할\u{201D} 전문 용어만 남겨라.

      남길 것: 개념·기법·이론의 이름 (예: 객체 지향 프로그래밍, 경사 하강법, 정규 표현식)
      뺄 것:
      - 슬라이드에 적힌 코드 조각·예약어·변수명 (public class, static void, int age, div class)
      - 파일 경로·URL·명령어 (git clone, https, npm run)
      - 문서 제목·머리말·과정명·강사명
      - 뜻이 잘리거나 조각난 말 (래스, 프로, Ent)
      - 너무 일반적이어서 어느 수업에나 나오는 말 (핵심 내용, 개념 이해, 종합 실습)

      한글로만 된 용어는 웬만하면 남겨라. 지울지 말지 애매하면 남기는 쪽을 골라라.
      목록에 없는 말을 새로 만들지 마라. 순서는 받은 그대로 유지해라.
      """
    let body: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": "후보 \(candidates.count)개:\n" + candidates.joined(separator: "\n")],
      ],
      "stream": false,
      "format": termFilterSchema,
      "think": false,
      "keep_alive": 0,
      "options": ["temperature": 0, "num_ctx": 8192],
    ]

    guard let url = URL(string: "\(host)/api/chat") else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 300

    guard let (data, response) = try? await URLSession.shared.data(for: req),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = root["message"] as? [String: Any],
          let content = message["content"] as? String,
          let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          let raw = parsed["terms"] as? [String]
    else {
      logWarn("교안 용어 LLM 정제 실패 — 규칙 결과를 그대로 씁니다.")
      return nil
    }

    // 모델이 없는 말을 지어내지 못하도록 원본에 있는 것만 통과시킨다.
    let allowed = Dictionary(candidates.map { ($0.replacingOccurrences(of: " ", with: "").lowercased(), $0) },
                             uniquingKeysWith: { a, _ in a })
    var kept: [String] = []
    var seen = Set<String>()
    for term in raw {
      let key = term.replacingOccurrences(of: " ", with: "").lowercased()
      guard let original = allowed[key], seen.insert(key).inserted else { continue }
      kept.append(original)
    }

    // 한글로만 된 용어는 모델이 지웠어도 되살린다.
    //
    // 실측: 모델이 잘못 지운 것 대부분이 "부모 클래스", "매개 변수", "자바 변수" 같은
    // 한글 개념어였다. 반대로 꼭 걸러야 할 코드 조각은 예외 없이 라틴 문자다.
    // 그래서 모델에게는 라틴 문자가 섞인 항목에 대해서만 판단을 맡긴다.
    let keptKeys = Set(kept.map { $0.replacingOccurrences(of: " ", with: "").lowercased() })
    var restored = 0
    for term in candidates {
      let key = term.replacingOccurrences(of: " ", with: "").lowercased()
      guard !keptKeys.contains(key) else { continue }
      let hasLatin = term.range(of: "[A-Za-z]", options: .regularExpression) != nil
      if !hasLatin {
        kept.append(term)
        restored += 1
      }
    }
    if restored > 0 { log("한글 전용 용어 \(restored)개는 모델 판단에서 되살렸습니다.") }
    // 원래 순위를 유지한다
    let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1, $0) })
    kept.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }

    // 너무 많이 지우면 판단을 신뢰하지 않는다.
    guard kept.count * 5 >= candidates.count else {
      logWarn("LLM 정제가 후보의 80% 넘게(\(candidates.count - kept.count)/\(candidates.count)) 지워서 무시합니다.")
      return nil
    }
    return kept
  }

  // MARK: - 문맥 다듬기 (자기 일관성 교정)

  /// 모델이 제안하는 교정 하나. segID 가 없다 — "이 표기를 이 표기로" 라는 규칙만
  /// 돌려주고, 녹취 전체에서 그 규칙이 맞는 자리를 찾는 건 호출부의 몫이다. 같은
  /// 실수가 여러 번 반복돼도 모델이 한 번만 판단하면 되므로 더 안정적이다.
  struct CorrectionSuggestion: Codable, Sendable {
    var before: String
    var after: String
    var reason: String
  }

  private static let correctionSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "corrections": [
        "type": "array",
        "items": [
          "type": "object",
          "properties": [
            "before": ["type": "string"],
            "after": ["type": "string"],
            "reason": ["type": "string"],
          ],
          "required": ["before", "after", "reason"],
        ],
      ],
    ],
    "required": ["corrections"],
  ]

  /// 강의 전체를 한 번에 넣고, 음성 인식이 잘못 알아들어 생긴 표기 불일치를 찾는다.
  /// 결과는 제안일 뿐이다 — 호출부가 원문에 실제로 있는지, 근거가 있는지 검증하고
  /// 반영 여부도 따로 정한다(이 함수는 아무것도 바꾸지 않는다).
  static func suggestCorrections(transcript: String, title: String,
                                 glossary: String, model: String) async throws -> [CorrectionSuggestion] {
    let glossaryLine = glossary.isEmpty
      ? "(교안 없음 — 녹취 안에서 같은 대상이 다르게 표기된 자리만 근거로 삼아라)"
      : glossary
    let system = """
      너는 한국어 강의 녹취록에서 음성 인식 오류를 잡아내는 전문 교정자다.
      특히 외래어·전문 용어가 한국어로 옮겨지며 발음이 비슷해서 잘못 들린 경우를
      알아채는 게 네 전문 분야다.

      이 강의 교안의 정확한 용어:
      \(glossaryLine)

      규칙:
      - 고칠 게 없는 문장은 corrections 목록에 아예 넣지 마라. 모든 문장을
        판단해서 적으라는 게 아니다 — 실제로 고칠 것이 있는 항목만 담아라.
        before 와 after 가 같은 항목은 절대 만들지 마라.
      - "같은 대상"이란 발음이 비슷해서 인식기가 다르게 받아적은 경우만 뜻한다.
        화자가 실제로 다른 낱말을 쓴 경우(동의어, 바꿔 말하기)는 대상이 아니다.
      - 교안 용어집이 최우선 기준이다. 교안에 있는 표기와 다르면, 녹취에 그 표기가
        한 번도 정확히 안 나왔어도 교안 표기로 고쳐라.
      - 교안에 없는 말은 녹취 다른 곳에 정확히 그대로 나온 경우에만 그 표기로 통일하고,
        그마저도 없으면 고치지 마라.
      - 어투·문법·반복·군말은 손대지 마라 — 인식 오류가 아닌 건 원문 그대로 둔다.
      - before 는 녹취 원문과 띄어쓰기·조사까지 글자 하나 다르지 않게 그대로 적어라.
      - 한두 글자짜리 흔한 표현은 고르지 마라 — 다른 문맥에서 우연히 같은 글자가
        나오면 엉뚱한 곳까지 고쳐질 수 있다.
      - 확신이 없으면(정말 같은 발음에서 갈라진 건지 의심되면) 목록에서 빼라.
        개수보다 정확도가 중요하다.
      """

    // 요약과 같은 추정식 재사용 — segID·타임스탬프가 없어 요약보다 입력이 짧다.
    let estimated = Int(Double(transcript.count) * tokensPerChar) + 800
    let numCtx = min(maxContext, max(8192, estimated + 1024))

    let body: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": "다음은 「\(title)」 녹취다.\n\n---\n\(transcript)\n---"],
      ],
      "stream": false,
      "format": correctionSchema,
      "think": false,
      "keep_alive": 0,
      // num_predict 없이 실측했더니 3000자짜리 작은 입력에서도 GPU 100%를 문 채
      // 160초 넘게 안 끝났다 — 요약(oneLine·keyPoints 몇 개)과 달리 이건 "찾는 대로
      // 계속 추가"하는 배열이라 모델이 반복 패턴에 걸리면 끝날 조건이 없다(오늘
      // 발견한 Whisper "팀에서" 반복 루프와 같은 종류). 교정 항목 하나가 대략
      // 60~90토큰이라 2048이면 20~30개까지 담기고(빡빡한 규칙상 실제로 이보다
      // 훨씬 적게 나옴), 폭주해도 1~2분 안에 강제로 끊긴다.
      "options": ["temperature": 0, "num_ctx": numCtx, "num_predict": 2048],
    ]

    guard let url = URL(string: "\(host)/api/chat") else { throw OllamaError.notRunning }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 900

    log("Ollama 다듬기 요청 — 모델 \(model), 입력 \(transcript.count)자, num_ctx \(numCtx)")
    let startedAt = Date()
    let (data, response) = try await URLSession.shared.data(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw OllamaError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "?")
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = root["message"] as? [String: Any],
          let content = message["content"] as? String,
          let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          let rawList = parsed["corrections"] as? [[String: Any]]
    else { throw OllamaError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "?") }

    let suggestions: [CorrectionSuggestion] = rawList.compactMap { item in
      guard let before = item["before"] as? String, let after = item["after"] as? String,
            !before.isEmpty, !after.isEmpty, before != after else { return nil }
      return CorrectionSuggestion(before: before, after: after, reason: item["reason"] as? String ?? "")
    }
    log("Ollama 다듬기 완료 — \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))초, "
      + "제안 \(suggestions.count)건")
    return suggestions
  }
}

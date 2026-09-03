import Foundation

/// whisper.cpp 로 저장된 소리를 다시 전사한다.
///
/// 실시간 자막은 SpeechTranscriber 가 맡는다 — 지연이 없어야 하니까.
/// Whisper 는 수업이 끝난 뒤 같은 소리를 처음부터 다시 들어 정확도를 끌어올리는 쪽이다.
/// 실측(M5): 30초에 1.1초, 실시간의 27배. 2시간 강의 전체가 5분이면 끝난다.
enum Whisper {

  // MARK: - 설치 확인

  private static let binaryCandidates = [
    "/opt/homebrew/bin/whisper-cli",
    "/usr/local/bin/whisper-cli",
    "/opt/homebrew/bin/whisper-cpp",
  ]

  static var binaryPath: String? {
    binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// 모델 파일을 찾는다. large-v3-turbo 를 가장 앞에 둔다 —
  /// 실측에서 medium 보다 빠르면서 더 정확했다.
  static var modelPath: URL? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["ZOOMCAPTION_WHISPER_MODEL"],
       fm.fileExists(atPath: env) { return URL(fileURLWithPath: env) }

    let dirs = [
      fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper", isDirectory: true),
      URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"),
      fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ZoomCaption/models", isDirectory: true),
    ]
    var found: [URL] = []
    for dir in dirs {
      guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
      found += names.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
                    // VAD 모델도 ggml-*.bin 이라 여기 걸린다. 전사 모델이 아니므로 빼야 한다.
                    .filter { !$0.contains("silero") }
                    .map { dir.appendingPathComponent($0) }
    }
    let rank: (URL) -> Int = { url in
      let n = url.lastPathComponent
      if n.contains("large-v3-turbo") { return 0 }
      if n.contains("large") { return 1 }
      if n.contains("medium") { return 2 }
      return 3
    }
    return found.min { rank($0) < rank($1) }
  }

  /// 무음 검출(VAD) 모델. 없으면 VAD 없이 돈다 — 있으면 좋고 없어도 되는 부품이다.
  ///
  /// **왜 쓰는가.** Whisper 는 30초 덩어리를 받으면 끝까지 뭔가를 채워야 하는 구조라
  /// 무음에서 문장을 지어낸다. 실측(java3 1100~1400초, 무음 173초):
  /// ```
  /// VAD 없음:  Thank you. × 4 + 「네, 다음으로 통화하겠습니다」  ← 전부 환각
  /// VAD 있음:  0건. 진짜 발화는 하나도 안 잃음
  /// ```
  /// 덤으로 처리할 오디오가 줄어 **2배 빨라졌다**(13.2초 → 6.2초).
  static var vadModelPath: URL? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["ZOOMCAPTION_VAD_MODEL"],
       fm.fileExists(atPath: env) { return URL(fileURLWithPath: env) }
    let dirs = [
      fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper", isDirectory: true),
      URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"),
      fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ZoomCaption/models", isDirectory: true),
    ]
    for dir in dirs {
      guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
      if let hit = names.first(where: { $0.contains("silero") && $0.hasSuffix(".bin") }) {
        return dir.appendingPathComponent(hit)
      }
    }
    return nil
  }

  /// 말 사이 짧은 쉼에서 끊지 않을 최소 무음 길이(ms).
  ///
  /// 기본값 100ms 는 너무 짧아 한 문장을 여러 조각으로 쪼갠다. 문맥이 파편화되면
  /// 영문 식별자 인식이 흔들린다 — 실측에서 100ms 는 용어 유지율 59%, 500ms 는 72%였다.
  /// (참고: VAD 없이 조각 경계만 15초 옮겨도 59%가 나온다. 즉 이 정도 흔들림은 원래 있다.)
  static let vadMinSilenceMs = 500
  /// 발화 앞뒤로 남길 여유(ms). 기본 30ms 는 낱말 끝이 잘릴 만큼 빠듯하다.
  static let vadSpeechPadMs = 200
  /// 문제가 생기면 껐다가 비교할 수 있게. `ZOOMCAPTION_NO_VAD=1`
  static var vadDisabled: Bool {
    ProcessInfo.processInfo.environment["ZOOMCAPTION_NO_VAD"] == "1"
  }

  static var isReady: Bool { binaryPath != nil && modelPath != nil }

  /// 왜 못 쓰는지 사람이 읽을 수 있게.
  static var status: (ready: Bool, detail: String) {
    switch (binaryPath, modelPath) {
    case (nil, _):
      return (false, "whisper-cli 가 없습니다 — 터미널에서 brew install whisper-cpp")
    case (_, nil):
      return (false, "모델 파일이 없습니다 — setup.sh 를 다시 실행하면 내려받습니다")
    case (let bin?, let model?):
      let mb = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int64)
        .flatMap { $0 } ?? 0
      return (true, "\(model.lastPathComponent) (\(mb / 1_048_576)MB) · \((bin as NSString).lastPathComponent)")
    }
  }

  // MARK: - 전사

  struct Line: Sendable {
    var start: Double
    var end: Double
    var text: String
    /// 이 줄을 이룬 whisper 토큰들(원 순서대로). 확신도 낮은 곳을 나중에
    /// 골라내는 데 쓴다 — 문장 재구성(SentenceReconstructor)은 이걸 안 쓰고
    /// 텍스트만 보므로, 기본값을 둬서 그쪽 생성자엔 영향이 없게 한다.
    var tokens: [Token] = []
  }

  /// whisper 토큰 하나 — 확률(p)이 낮을수록 모델이 자신 없어 한 자리다.
  /// (실측 2026-09-03: 정상 인식인데도 흔한 단어는 p 가 0.03~0.4 로 낮게
  /// 나오기도 한다 — 이 값 하나만으로 오인식을 단정하면 안 된다.)
  struct Token: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    var p: Double
    /// 이 토큰이 새 낱말(어절)의 시작인가. whisper 토큰은 낱말이 시작할 때만
    /// 텍스트 앞에 공백을 붙여 준다("남"/"궁"/"도" 세 토큰이 "남궁도" 한
    /// 낱말이면 "남"만 참) — 트리밍하기 전에 검사해야 한다(트리밍하면 이 신호가
    /// 사라진다). 여러 토큰을 낱말 단위로 묶을 때 경계로 쓴다(Store.computeFlags).
    var startsWord: Bool
  }

  /// WAV 하나를 통째로 다시 전사한다.
  /// - Parameter prompt: 교안 용어. Whisper 의 initial prompt 로 들어가 전문용어 표기를 잡아 준다.
  /// - Parameter onProgress: 0~1
  static func transcribe(wav: URL,
                         locale: String = "ko",
                         prompt: String = "",
                         onProgress: @escaping @Sendable (Double) -> Void) async -> [Line]? {
    guard let bin = binaryPath, let model = modelPath else { return nil }

    let stem = FileManager.default.temporaryDirectory
      .appendingPathComponent("zoomcaption-whisper-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stem.appendingPathExtension("json")) }

    var args = [
      "-m", model.path,
      "-f", wav.path,
      "-l", locale,
      "-ojf", "-of", stem.path,                      // -ojf: 토큰별 확률(p)까지 JSON 에 포함
      "-pp",                                        // 진행률을 stderr 로 흘린다
      "-t", String(min(8, ProcessInfo.processInfo.activeProcessorCount)),
    ]
    if !prompt.isEmpty {
      // 청크마다 다시 넣어야 뒤쪽 문단에서도 용어가 유지된다.
      args += ["--prompt", prompt, "--carry-initial-prompt"]
    }
    // 무음을 인코더에 넣지 않는다. 환각의 원인을 입구에서 없애는 쪽이다.
    // 모델이 없으면 그냥 건너뛴다 — VAD 는 있으면 좋은 부품이지 필수가 아니다.
    if !Self.vadDisabled, let vad = Self.vadModelPath {
      args += ["--vad", "-vm", vad.path,
               "-vsd", String(Self.vadMinSilenceMs),
               "-vp", String(Self.vadSpeechPadMs)]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    process.standardError = errPipe

    // stderr 는 두 가지로 쓴다: 진행률 파싱, 그리고 실패했을 때 원인 추적.
    // 진행 로그가 수천 줄이라 통째로 남기면 로그가 묻힌다. 끝부분만 들고 있는다.
    let tailLock = NSLock()
    var tail: [String] = []
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      guard let s = String(data: handle.availableData, encoding: .utf8), !s.isEmpty else { return }
      for line in s.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        if let r = trimmed.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression) {
          let digits = trimmed[r].filter(\.isNumber)
          if let pct = Double(digits) { onProgress(min(1, pct / 100)) }
          continue                                   // 진행률 줄은 보관하지 않는다
        }
        tailLock.withLock {
          tail.append(trimmed)
          if tail.count > 40 { tail.removeFirst(tail.count - 40) }
        }
      }
    }

    log("whisper 실행: \(((bin as NSString).lastPathComponent)) "
      + "\(model.lastPathComponent) ← \(wav.lastPathComponent)"
      + (prompt.isEmpty ? "" : " (용어 힌트 있음)")
      + (args.contains("--vad") ? " (VAD 켬)" : " (VAD 없음)"))

    do { try process.run() } catch {
      logError("whisper 를 실행하지 못했습니다: \(error.localizedDescription) — 경로 \(bin)")
      return nil
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in c.resume() }
    }
    errPipe.fileHandleForReading.readabilityHandler = nil

    guard process.terminationStatus == 0 else {
      let detail = tailLock.withLock { tail.suffix(12).joined(separator: " | ") }
      logError("whisper 가 코드 \(process.terminationStatus) 로 끝났습니다 — \(wav.lastPathComponent)")
      logError("whisper stderr: \(detail.isEmpty ? "(출력 없음)" : detail)")
      return nil
    }
    guard let lines = parse(stem.appendingPathExtension("json")) else {
      let detail = tailLock.withLock { tail.suffix(12).joined(separator: " | ") }
      logError("whisper stderr: \(detail.isEmpty ? "(출력 없음)" : detail)")
      return nil
    }
    return lines
  }

  /// whisper-cli 의 JSON 출력에서 시각과 문장만 뽑는다.
  private static func parse(_ url: URL) -> [Line]? {
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = root["transcription"] as? [[String: Any]]
    else {
      logError("whisper JSON 을 읽지 못했습니다: \(url.lastPathComponent)")
      return nil
    }
    return items.compactMap { item -> Line? in
      guard let offsets = item["offsets"] as? [String: Any],
            let from = offsets["from"] as? Double ?? (offsets["from"] as? Int).map(Double.init),
            let to = offsets["to"] as? Double ?? (offsets["to"] as? Int).map(Double.init),
            let raw = item["text"] as? String
      else { return nil }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      // 무음 구간에서 Whisper 가 흘리는 상투어를 버린다.
      guard !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
      let tokens = parseTokens(item["tokens"] as? [[String: Any]] ?? [], segmentFromMs: from)
      return Line(start: from / 1000, end: to / 1000, text: text, tokens: tokens)
    }
  }

  /// `-ojf` 가 세그먼트마다 붙여 주는 토큰 목록을 읽는다. `[_BEG_]`, `[_TT_380]` 같은
  /// 특수 토큰(실제 발화가 아니라 디코더 내부 표식)은 뺀다.
  ///
  /// **VAD 시간축 보정(실측 2026-09-03).** VAD 를 켜면(기본값) whisper 가 무음을
  /// 잘라 이어붙인 내부 시간축으로 디코딩한다. 세그먼트 경계(위 `parse` 의
  /// `offsets.from/to`)는 원래 시간으로 되돌려 주지만, **토큰 하나하나의 offsets 는
  /// 그 되돌리기를 안 거친 값 그대로 나온다** — VAD 끄고 같은 오디오를 다시 돌려
  /// "세그먼트 시작 == 그 세그먼트의 첫 토큰 offsets.from" 이 되는 것으로 확인했다
  /// (VAD 있으면 어긋나고, 뒤로 갈수록 더 벌어진다 — 누적된 무음만큼). 한 세그먼트
  /// 안에서는 이 어긋난 정도가 거의 일정하므로("세그먼트의 진짜 시작" −
  /// "그 세그먼트 원시 토큰의 첫 offsets.from")를 보정값으로 구해 모든 토큰에 같이
  /// 더한다.
  private static func parseTokens(_ raw: [[String: Any]], segmentFromMs: Double) -> [Token] {
    guard let firstRawFrom = raw.first.flatMap({ t -> Double? in
      (t["offsets"] as? [String: Any]).flatMap { o in
        o["from"] as? Double ?? (o["from"] as? Int).map(Double.init)
      }
    }) else { return [] }
    let correction = segmentFromMs - firstRawFrom

    return raw.compactMap { t -> Token? in
      guard let text = t["text"] as? String, !text.hasPrefix("[_"),
            let offsets = t["offsets"] as? [String: Any],
            let from = offsets["from"] as? Double ?? (offsets["from"] as? Int).map(Double.init),
            let to = offsets["to"] as? Double ?? (offsets["to"] as? Int).map(Double.init),
            let p = t["p"] as? Double
      else { return nil }
      let startsWord = text.hasPrefix(" ")   // 트리밍 전에 검사 — 공백이 낱말 경계 신호다
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return nil }
      return Token(text: trimmed, start: (from + correction) / 1000, end: (to + correction) / 1000,
                  p: p, startsWord: startsWord)
    }
  }
}

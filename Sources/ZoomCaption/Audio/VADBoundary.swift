import Foundation

/// 오디오를 자를 때 정확히 목표 초에서 끊지 않고, 그 근처의 **진짜 쉬는 지점**을 찾아 끊는다.
///
/// 지금까지는(WhisperLive) 30.000초에서 무조건 자르고, 문장이 걸리는 걸 2초 겹침 +
/// 중복 제거 필터로 땜질해 왔다. 실측(50분 강의 java3)해 보니 30초·60초 지점 근처에
/// 1.4~1.6초짜리 무음이 실제로 있었다 — 그 자리에서 자르면 애초에 문장이 안 걸리므로
/// 겹침도 중복 제거도 필요 없어진다.
enum VADBoundary {
  struct SpeechSegment: Equatable { var start: Double; var end: Double }  // 초 단위

  private static let binaryCandidates = [
    "/opt/homebrew/bin/whisper-vad-speech-segments",
    "/usr/local/bin/whisper-vad-speech-segments",
  ]
  static var binaryPath: String? {
    binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// 발화가 이보다 길게 이어지면 강제로 끊는다. 화자가 목표 지점 근처에서 한 번도 안 쉬면
  /// 자를 후보 자체가 없어지는데, 이 값을 두면 최소한 하나는 항상 생긴다.
  /// 목표 조각 길이(30초)보다 살짝 크게 잡아서, 정상적인 쉼이 있는 경우엔 방해하지 않는다.
  static let maxSpeechSeconds = 35.0

  /// `wav` 안의 발화 구간을 초 단위로 돌려준다. 실패하면 nil — 호출부는 목표 지점에서
  /// 그냥 자르는 것으로 폴백해야 한다(VAD는 없어도 되는 부품이다, Whisper.swift 와 같은 원칙).
  static func speechSegments(wav: URL, vadModel: URL) -> [SpeechSegment]? {
    guard let bin = binaryPath else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = [
      "-f", wav.path, "-vm", vadModel.path, "-np",
      "-vmsd", String(maxSpeechSeconds),
    ]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
      logWarn("VAD 경계 탐색 실행 실패: \(error.localizedDescription)")
      return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
      return nil
    }
    return parse(text)
  }

  /// "Speech segment 0: start = 58.00, end = 256.00" — 출력은 센티초(1/100초)다.
  private static func parse(_ text: String) -> [SpeechSegment] {
    guard let re = try? NSRegularExpression(
      pattern: #"start\s*=\s*([\d.]+),\s*end\s*=\s*([\d.]+)"#) else { return [] }
    let ns = text as NSString
    var out: [SpeechSegment] = []
    re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
      guard let m, m.numberOfRanges == 3,
            let start = Double(ns.substring(with: m.range(at: 1))),
            let end = Double(ns.substring(with: m.range(at: 2))) else { return }
      out.append(SpeechSegment(start: start / 100, end: end / 100))
    }
    return out.sorted { $0.start < $1.start }
  }

  /// 무음 구간을 찾으면 그 **뒤쪽 끝(다음 발화 시작 직전)** 에 이만큼만 여유를 두고 붙인다.
  ///
  /// 처음엔 무음 구간의 중간(또는 target 그 자리)을 썼는데, 실측(java3, 넓은 쉼 2건 —
  /// 7.4초·11.7초)에서 문제가 드러났다: 무음이 넓을 때 target 이 그 구간 **앞쪽**에 걸리면
  /// 뒤 조각이 그 무음을 통째로 머리에 이고 시작한다. 그 조각을 whisper.cpp 가 독립된
  /// 프로세스로(콜드 스타트, 앞 문맥 없음) 전사하면서, 긴 무음 뒤에 이어지는 **진짜 말까지
  /// 같이 무음으로 오판해 삼켰다** — 사라진 길이가 원래 무음 길이와 거의 일치했다.
  ///
  /// 앞 조각 쪽에 남는 무음(꼬리)은 반대로 문제가 안 된다 — 그 뒤에 아무 말도 없으니
  /// whisper 가 조용히 건너뛸 뿐이다. 그래서 대칭으로 반을 가르지 않고 뒤쪽 끝에 붙인다.
  private static let trailingSafetyMargin = 0.4

  /// `target` 초 근처에서 자를 지점을 찾는다.
  ///
  /// 무음이 지나치게 넓으면(쉬는 시간 등) 뒤쪽 끝까지 따라가지 않고 `target + maxSearch`
  /// 에서 멈춘다 — 그래야 조각 하나가 한없이 커지지 않는다. 반경 안에 무음 후보가 아예
  /// 없으면(35초 안전장치까지 뚫린 극단적 경우) nil — 호출부는 target 에서 그냥 자른다.
  static func cutPoint(near target: Double, in segments: [SpeechSegment], maxSearch: Double = 10) -> Double? {
    guard !segments.isEmpty else { return target }

    // (이전 발화 끝, 다음 발화 시작) 으로 무음 구간을 전부 나열한다.
    // 마지막 발화 뒤는 다음 발화가 없으니 hi 를 nil 로 둔다.
    var gaps: [(lo: Double, hi: Double?)] = []
    var prevEnd = 0.0
    for seg in segments {
      if seg.start > prevEnd { gaps.append((prevEnd, seg.start)) }
      prevEnd = max(prevEnd, seg.end)
    }
    gaps.append((prevEnd, nil))

    func biasedCut(_ g: (lo: Double, hi: Double?)) -> Double {
      guard let hi = g.hi else { return max(g.lo, target) }
      let ideal = hi - Self.trailingSafetyMargin
      return max(g.lo, min(ideal, target + maxSearch))
    }

    if let containing = gaps.first(where: { $0.lo <= target && ($0.hi.map { target <= $0 } ?? true) }) {
      return biasedCut(containing)
    }

    // target 이 발화 위 — 반경 안에서 가장 가까운 무음 구간을 찾는다. "가깝다"의 기준도
    // 실제로 자를 지점(뒤쪽 끝)으로 재야 일관된다.
    let inRange = gaps.filter { g in
      let probe = g.hi ?? g.lo
      return abs(probe - target) <= maxSearch
    }
    guard let best = inRange.min(by: {
      let a = $0.hi ?? $0.lo, b = $1.hi ?? $1.lo
      return abs(a - target) < abs(b - target)
    }) else { return nil }
    return biasedCut(best)
  }
}

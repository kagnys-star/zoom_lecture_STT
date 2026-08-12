import Foundation

/// 수업이 도는 동안 Whisper 를 뒤에서 돌린다.
///
/// Whisper 는 실시간의 27배라 90분 강의에 3분 20초면 끝난다. 듀티 사이클로 치면 4% 다.
/// 그 여유를 수업 시간에 흘려 넣으면, 정지를 누르는 순간 재전사가 **이미 끝나 있다**.
/// 코어를 더 쓰지 않고 대기 시간만 없애는 방법이라 병렬화보다 이쪽이 남는 장사다.
///
/// 조각은 반드시 **한 번에 하나씩** 처리한다. 동시에 여러 개를 돌리면
/// Metal 을 시분할할 뿐이라 총 시간은 그대로인데 메모리만 547MB 씩 늘어난다.
final class WhisperLive: @unchecked Sendable {

  struct Line: Sendable {
    var start: Double
    var end: Double
    var text: String
  }

  private let prompt: String
  private let onLines: @Sendable ([Line]) -> Void
  private let onProgress: @Sendable (Int, Int) -> Void

  private let lock = NSLock()
  private var queue: [(url: URL, start: Double)] = []
  private var draining = false
  private var stopped = false
  private var _done = 0
  private var _queued = 0

  /// 처리한 조각 수 / 들어온 조각 수
  var progress: (done: Int, total: Int) { lock.withLock { (_done, _queued) } }

  init(prompt: String,
       onLines: @escaping @Sendable ([Line]) -> Void,
       onProgress: @escaping @Sendable (Int, Int) -> Void) {
    self.prompt = prompt
    self.onLines = onLines
    self.onProgress = onProgress
  }

  /// 오디오 콜백에서 불릴 수 있으므로 여기서는 큐에 넣기만 한다.
  func enqueue(url: URL, start: Double) {
    let shouldStart: Bool = lock.withLock {
      guard !stopped else { return false }
      queue.append((url, start))
      _queued += 1
      if draining { return false }
      draining = true
      return true
    }
    if shouldStart { Task.detached(priority: .utility) { await self.drain() } }
  }

  private func drain() async {
    while true {
      let next: (url: URL, start: Double)? = lock.withLock {
        if stopped || queue.isEmpty { draining = false; return nil }
        return queue.removeFirst()
      }
      guard let job = next else { return }

      let lines = await Whisper.transcribe(wav: job.url, prompt: prompt) { _ in }
      try? FileManager.default.removeItem(at: job.url)   // 원본은 세션 WAV 에 다 있다

      if let lines, !lines.isEmpty {
        // 조각 안의 시각을 세션 타임라인으로 옮긴다.
        // 앞 조각과 겹친 구간에서 이미 나온 말은 버린다 — 겹침 안에서 끝나는 조각만 버리고,
        // 경계를 걸친 문장은 살려서 잘린 단어가 사라지지 않게 한다.
        let overlap = AudioArchive.overlapSeconds
        let isFirst = job.start <= 0.001
        let kept = lines.filter { isFirst || $0.end > overlap }
        onLines(kept.map { Line(start: $0.start + job.start,
                                end: $0.end + job.start, text: $0.text) })
      }

      let snapshot: (Int, Int) = lock.withLock { _done += 1; return (_done, _queued) }
      onProgress(snapshot.0, snapshot.1)
    }
  }

  /// 더 받지 않는다. 이미 큐에 있는 건 끝까지 처리한다.
  func seal() { lock.withLock { } }

  /// 남은 조각까지 다 끝날 때까지 기다린다. 정지 직후 저장 전에 부른다.
  func finish(timeout: TimeInterval = 180) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let idle: Bool = lock.withLock { queue.isEmpty && !draining }
      if idle { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
    logWarn("Whisper 조각 처리가 \(Int(timeout))초 안에 끝나지 않아 남은 것은 버립니다.")
    lock.withLock { stopped = true; queue.removeAll() }
  }

  func cancel() {
    lock.withLock {
      stopped = true
      for job in queue { try? FileManager.default.removeItem(at: job.url) }
      queue.removeAll()
    }
  }
}

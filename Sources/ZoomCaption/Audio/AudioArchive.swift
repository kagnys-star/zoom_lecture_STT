import Foundation
import AVFoundation

/// 캡처한 소리를 세션 폴더에 WAV 로 남긴다.
///
/// 자막만 저장하면 나중에 다시 손볼 방법이 없다. 인식이 틀린 자리를 찾아도
/// 원본 소리가 없으면 확인도 재전사도 못 한다. 그래서 소리를 같이 남긴다.
///
/// 포맷은 **16kHz mono Int16** 이다. 전사기가 요구하는 포맷과 같고,
/// Whisper 계열이 그대로 받는 포맷이기도 하다. 용량은 시간당 약 110MB.
/// 원본(48kHz 스테레오)을 그대로 두면 시간당 1.3GB 라 수업 기록으로 쓰기 어렵다.
final class AudioArchive: @unchecked Sendable {

  /// 세션 폴더에 쌓인 소리 조각들을 시간순으로 돌려준다.
  /// 파일 이름(`audio_012345.wav`)이 곧 세션 타임라인의 시작 초다.
  static func clips(in dir: URL) -> [(url: URL, startOffset: Double, bytes: Int64)] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
    return names
      .filter { $0.hasPrefix("audio_") && $0.hasSuffix(".wav") }
      .compactMap { name in
        let digits = name.dropFirst("audio_".count).dropLast(".wav".count)
        guard let offset = Double(digits) else { return nil }
        let url = dir.appendingPathComponent(name)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
        return (url, offset, size)
      }
      .sorted { $0.startOffset < $1.startOffset }
  }

  /// 이 클립이 세션 타임라인의 몇 초 지점에서 시작하는지.
  /// 이어 적기로 녹음이 나뉘어도 자막 시각에서 소리 위치를 되찾을 수 있게 파일 이름에 박아 둔다.
  let startOffset: Double
  let url: URL

  /// 조각 하나가 준비될 때마다 부른다. (조각 파일, 세션 타임라인에서의 시작 초)
  /// 수업이 도는 동안 Whisper 를 뒤에서 돌리기 위한 통로다.
  var onChunk: (@Sendable (URL, Double) -> Void)?

  /// Whisper 에 넘길 조각의 목표 길이. 정확히 이 지점에서 자르지 않고, 이 근처의
  /// 자연스러운 쉼(`VADBoundary`)을 찾아 자른다 — 그래서 겹침도 중복 제거도 필요 없다.
  static let chunkTargetSeconds = 30.0
  /// 화면엔 실시간(Apple) 이 곧바로 뜨고, 그보다 이만큼 지난 구간부터 Whisper 로 갈아
  /// 끼운다. Whisper 를 수업 내내 실시간으로 돌리지 않고 한 박자 늦게 뒤따라가게 해서,
  /// 두 엔진이 동시에 GPU 를 다투는 걸 줄이려는 의도다.
  static let releaseDelaySeconds = 60.0
  /// 이만큼 쌓여야 한 조각을 내보낸다 — 그래야 내보낸 조각의 **끝**이 항상
  /// releaseDelaySeconds 이상 지난 상태가 된다(30초를 떼어내도 60초가 그대로 남는다).
  private static var triggerSeconds: Double { chunkTargetSeconds + releaseDelaySeconds }
  /// VAD 로 쉼을 찾을 때 목표 지점 앞뒤로 볼 여유. 이 범위 안에 쉼이 없으면
  /// `VADBoundary.maxSpeechSeconds` 강제 분할에 걸린다.
  private static let vadSearchRadius = 10.0

  private static let rate = 16_000.0
  private var triggerCapacity: Int { Int(Self.triggerSeconds * Self.rate) }
  private var targetCutSamples: Int { Int(Self.chunkTargetSeconds * Self.rate) }

  private let lock = NSLock()
  private var file: AVAudioFile?
  private let resampler: AudioResampler
  private var _frames: Int64 = 0
  private var failed = false

  /// 아직 조각으로 안 나간 샘플.
  private var pending: [Int16] = []
  /// 지금까지 조각으로 내보낸 샘플 수 (조각 시작 시각 계산용)
  private var emitted: Int = 0
  private var chunkIndex = 0
  private let chunkDir: URL
  /// VAD 로 자를 지점을 찾는 동안(프로세스 실행, 수백 ms) 오디오 콜백 스레드를 막으면
  /// 안 된다 — 그래서 백그라운드로 뺀다. 이미 하나가 도는 중이면 더 안 띄운다,
  /// Whisper 조각을 한 번에 하나씩만 처리하는 것과 같은 이유다.
  private var cutting = false

  /// 저장된 길이(초)
  var duration: Double { lock.withLock { Double(_frames) / 16_000 } }
  var byteCount: Int64 { lock.withLock { _frames * 2 } }

  init(dir: URL, startOffset: Double) throws {
    self.startOffset = startOffset
    let name = String(format: "audio_%06d.wav", Int(startOffset.rounded()))
    self.url = dir.appendingPathComponent(name)

    // 세션 폴더가 사라졌을 수도 있다(밖에서 옮기거나 지운 경우).
    // 여기서 만들어 두지 않으면 소리 저장이 통째로 실패하고, 그러면 Whisper 도 굶는다.
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Whisper 가 바로 먹을 수 있는 형태로 고정한다.
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let f = try AVAudioFile(forWriting: url, settings: settings,
                            commonFormat: .pcmFormatInt16, interleaved: true)
    self.file = f
    self.resampler = AudioResampler(target: f.processingFormat)

    // 조각은 임시 폴더에 둔다. 전사가 끝나면 지운다 — 원본은 위 WAV 에 다 있다.
    chunkDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zoomcaption-chunks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
  }

  /// 무음으로 볼 진폭 상한. Int16 기준 250 ≈ −42 dBFS 로, 사람 말소리는 훨씬 크게 잡힌다.
  ///
  /// 무음 조각을 Whisper 에 넣으면 안 된다. 학습 분포 밖이라 없는 말을 지어낸다 —
  /// 실측에서 조용한 30초에 "자막 제공 및 광고를 포함하고 있습니다" 를 두 번 뱉었다.
  /// 수업에는 쉬는 시간과 침묵이 많아서 그대로 두면 정식 기록이 헛소리로 오염된다.
  private static let silenceCeiling: Int16 = 250

  /// PCM 샘플을 WAV 파일로 쓴다. 조각 하나 쓰는 데도, VAD 탐색용 미리보기 쓰는 데도 쓴다.
  private func writeWav(_ samples: [Int16], to fileURL: URL) -> Bool {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate,
                                     channels: 1, interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(samples.count)),
          let dst = buffer.int16ChannelData
    else { return false }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
      dst[0].update(from: src.baseAddress!, count: samples.count)
    }
    do {
      let out = try AVAudioFile(forWriting: fileURL, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      ], commonFormat: .pcmFormatInt16, interleaved: true)
      try out.write(from: buffer)
      return true
    } catch {
      return false
    }
  }

  /// 모아둔 샘플을 조각 WAV 로 떨어뜨린다. 락 밖에서 부른다(백그라운드 작업이라 안전).
  private func flushChunk(_ samples: [Int16], startSample: Int, index: Int) {
    var peak: Int16 = 0
    for i in stride(from: 0, to: samples.count, by: 8) {   // 8샘플마다 훑어도 충분하다
      let v = samples[i] == Int16.min ? Int16.max : abs(samples[i])
      if v > peak { peak = v }
    }
    guard peak > Self.silenceCeiling else {
      log("조용한 구간이라 Whisper 에 넘기지 않습니다 (피크 \(peak), 약 \(Int(Double(samples.count) / Self.rate))초)")
      return
    }
    let chunkURL = chunkDir.appendingPathComponent(String(format: "chunk_%04d.wav", index))
    guard writeWav(samples, to: chunkURL) else {
      logWarn("오디오 조각을 쓰지 못했습니다")
      return
    }
    let start = startOffset + Double(startSample) / Self.rate
    onChunk?(chunkURL, start)
  }

  /// 목표 지점(조각 앞에서 `chunkTargetSeconds`) 근처의 자연스러운 쉼을 찾아 자른다.
  /// VAD 를 못 쓰면(모델·바이너리 없음) 그냥 목표 지점에서 자른다 — 있으면 좋고
  /// 없어도 되는 부품이다(Whisper.swift 의 VAD 와 같은 원칙).
  ///
  /// 오디오 콜백 스레드가 아니라 백그라운드에서 돈다(`write()` 참고) — VAD 프로세스 실행에
  /// 수백 ms 걸리는데, 그걸 실시간 오디오 경로에서 기다리면 안 되기 때문이다.
  private func cutAndFlush(snapshot: [Int16], base: Int) {
    defer { lock.withLock { cutting = false } }

    // VAD 로 못 자르면(모델 없음, 후보 없음 등) 목표 지점에서 그냥 자른다 — 정상적으로는
    // 거의 안 일어난다(실측 java3 8개 전부 목표 근처에서 성공). 일어나면 그 조각만
    // 경계가 부정확할 수 있다는 뜻이라 남겨 둘 값어치가 있다.
    var cutSamples = targetCutSamples
    if let vad = Whisper.vadModelPath, VADBoundary.binaryPath != nil {
      let analysisSamples = min(snapshot.count,
        Int((Self.chunkTargetSeconds + Self.vadSearchRadius + 5) * Self.rate))
      let probeURL = chunkDir.appendingPathComponent("probe_\(UUID().uuidString).wav")
      if writeWav(Array(snapshot.prefix(analysisSamples)), to: probeURL) {
        if let segs = VADBoundary.speechSegments(wav: probeURL, vadModel: vad) {
          if let cutSeconds = VADBoundary.cutPoint(near: Self.chunkTargetSeconds, in: segs,
                                                    maxSearch: Self.vadSearchRadius) {
            cutSamples = min(snapshot.count, max(1, Int(cutSeconds * Self.rate)))
          } else {
            logWarn("이 조각은 \(Self.vadSearchRadius)초 반경 안에 쉼이 없어 목표 지점에서 그냥 잘랐습니다 — 문장이 걸렸을 수 있습니다.")
          }
        }
        try? FileManager.default.removeItem(at: probeURL)
      }
    }

    let body = Array(snapshot.prefix(cutSamples))
    let index: Int = lock.withLock {
      // snapshot 의 앞부분과 지금 pending 의 앞부분은 항상 같다 — 이 함수가 한 번에
      // 하나씩만 돌고(cutting 가드), pending 은 뒤로만 자라기 때문이다.
      if pending.count >= body.count { pending.removeFirst(body.count) }
      emitted = base + body.count
      defer { chunkIndex += 1 }
      return chunkIndex
    }
    flushChunk(body, startSample: base, index: index)
  }

  /// 오디오 콜백에서 바로 불린다. 여기서 실패해도 녹취는 계속되어야 한다.
  func write(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard let file, !failed else { return }
    guard let converted = resampler.convert(buffer) else { return }
    do {
      try file.write(from: converted)
      _frames += Int64(converted.frameLength)

      // 같은 샘플을 조각 버퍼에도 쌓아 둔다. releaseDelaySeconds + chunkTargetSeconds 만큼
      // 쌓이면 백그라운드로 잘라 내보낸다 — write() 자체는 계속 빨라야 하므로
      // 여기서 직접 자르지 않는다.
      if onChunk != nil, let src = converted.int16ChannelData {
        let n = Int(converted.frameLength)
        pending.append(contentsOf: UnsafeBufferPointer(start: src[0], count: n))
        if !cutting, pending.count >= triggerCapacity {
          cutting = true
          let snapshot = pending
          let base = emitted
          Task.detached(priority: .utility) { [weak self] in
            self?.cutAndFlush(snapshot: snapshot, base: base)
          }
        }
      }
    } catch {
      // 한 번 실패하면 매 버퍼마다 로그를 쏟지 않도록 한 번만 남기고 접는다.
      failed = true
      logWarn("오디오 저장 실패 — 이후 이 세션의 소리는 남기지 않습니다: \(error.localizedDescription)")
    }
  }

  /// 파일을 닫는다. 닫아야 WAV 헤더의 길이가 확정된다.
  @discardableResult
  func finish() async -> (url: URL, seconds: Double, bytes: Int64)? {
    // 지금 돌고 있는 컷 작업이 있으면 끝날 때까지 기다린다 — 안 그러면 그 작업이
    // pending 에서 떼어 가려던 부분과, 여기서 자투리로 통째로 내보내는 부분이 겹친다.
    while lock.withLock({ cutting }) {
      try? await Task.sleep(for: .milliseconds(50))
    }

    // flushChunk 는 파일 I/O 라 락 밖에서 부른다(withLock 안에서 부르면 async 컨텍스트의
    // 원시 lock()/unlock() 을 쓰게 되어 Swift 6 모드에서 금지된다). 필요한 값만 락 안에서
    // 빼내고, 상태(file=nil 등)도 그 안에서 미리 다 정리해 둔다.
    let result: (tail: (samples: [Int16], base: Int, index: Int)?, seconds: Double, bytes: Int64)?
      = lock.withLock {
        guard file != nil else { return nil }
        // 남은 자투리도 마지막 조각으로 내보낸다. 마지막이라 다음 조각과 겹칠 걱정이
        // 없으니 VAD 로 자를 지점을 찾을 필요도 없다 — 있는 그대로 다 넘긴다.
        // 너무 짧으면 Whisper 가 헛소리를 하므로 2초를 하한으로 둔다.
        var tail: (samples: [Int16], base: Int, index: Int)?
        if onChunk != nil, pending.count >= Int(2 * Self.rate) {
          tail = (pending, emitted, chunkIndex)
          chunkIndex += 1
          emitted += pending.count
          pending.removeAll()
        }
        file = nil                   // AVAudioFile 은 해제될 때 헤더를 마무리한다
        return (tail, Double(_frames) / 16_000, _frames * 2)
      }
    guard let result else { return nil }
    if let tail = result.tail {
      flushChunk(tail.samples, startSample: tail.base, index: tail.index)
    }
    let seconds = result.seconds
    // 소리가 거의 없으면 껍데기 파일을 남기지 않는다.
    if seconds < 0.5 {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return (url, seconds, result.bytes)
  }
}

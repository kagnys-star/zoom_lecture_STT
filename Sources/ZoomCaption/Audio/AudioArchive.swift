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

  /// 30초가 모일 때마다 부른다. (조각 파일, 세션 타임라인에서의 시작 초)
  /// 수업이 도는 동안 Whisper 를 뒤에서 돌리기 위한 통로다.
  var onChunk: (@Sendable (URL, Double) -> Void)?

  /// Whisper 인코더가 30초 고정이라 조각도 30초로 맞춘다. 더 잘게 자르면 손해만 난다.
  static let chunkSeconds = 30.0
  /// 조각 경계에서 단어가 잘리는 걸 막는 겹침. 앞 조각의 꼬리를 붙여서 보낸다.
  static let overlapSeconds = 2.0

  private static let rate = 16_000.0
  private var chunkCapacity: Int { Int(Self.chunkSeconds * Self.rate) }
  private var overlapCapacity: Int { Int(Self.overlapSeconds * Self.rate) }

  private let lock = NSLock()
  private var file: AVAudioFile?
  private let resampler: AudioResampler
  private var _frames: Int64 = 0
  private var failed = false

  /// 아직 조각으로 안 나간 샘플, 그리고 다음 조각 앞에 붙일 꼬리
  private var pending: [Int16] = []
  private var tail: [Int16] = []
  /// 지금까지 조각으로 내보낸 샘플 수 (조각 시작 시각 계산용)
  private var emitted: Int = 0
  private var chunkIndex = 0
  private let chunkDir: URL

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

  /// 모아둔 샘플을 조각 WAV 로 떨어뜨린다. lock 을 쥔 채로 부른다.
  private func flushChunk(_ samples: [Int16], startSample: Int) {
    var peak: Int16 = 0
    for i in stride(from: 0, to: samples.count, by: 8) {   // 8샘플마다 훑어도 충분하다
      let v = samples[i] == Int16.min ? Int16.max : abs(samples[i])
      if v > peak { peak = v }
    }
    guard peak > Self.silenceCeiling else {
      log("조용한 구간이라 Whisper 에 넘기지 않습니다 (피크 \(peak), 약 \(Int(Double(samples.count) / Self.rate))초)")
      return
    }
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate,
                                     channels: 1, interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(samples.count)),
          let dst = buffer.int16ChannelData
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
      dst[0].update(from: src.baseAddress!, count: samples.count)
    }

    let url = chunkDir.appendingPathComponent(String(format: "chunk_%04d.wav", chunkIndex))
    chunkIndex += 1
    do {
      let out = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      ], commonFormat: .pcmFormatInt16, interleaved: true)
      try out.write(from: buffer)
    } catch {
      logWarn("오디오 조각을 쓰지 못했습니다: \(error.localizedDescription)")
      return
    }
    // 조각의 시작 시각. 겹쳐 붙인 꼬리만큼 앞으로 당겨진다.
    let start = startOffset + Double(startSample) / Self.rate
    onChunk?(url, start)
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

      // 같은 샘플을 조각 버퍼에도 쌓아 둔다. 30초가 차면 뒤로 넘긴다.
      if onChunk != nil, let src = converted.int16ChannelData {
        let n = Int(converted.frameLength)
        pending.append(contentsOf: UnsafeBufferPointer(start: src[0], count: n))
        while pending.count >= chunkCapacity {
          let body = Array(pending.prefix(chunkCapacity))
          pending.removeFirst(chunkCapacity)
          // 앞 조각의 꼬리를 붙여 경계에서 단어가 잘리지 않게 한다.
          flushChunk(tail + body, startSample: emitted - tail.count)
          emitted += chunkCapacity
          tail = Array(body.suffix(overlapCapacity))
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
  func finish() -> (url: URL, seconds: Double, bytes: Int64)? {
    lock.lock()
    defer { lock.unlock() }
    guard file != nil else { return nil }

    // 남은 자투리도 마지막 조각으로 내보낸다. 너무 짧으면 Whisper 가 헛소리를 하므로 2초를 하한으로 둔다.
    if onChunk != nil, pending.count >= Int(2 * Self.rate) {
      flushChunk(tail + pending, startSample: emitted - tail.count)
      emitted += pending.count
      pending.removeAll()
    }
    file = nil                       // AVAudioFile 은 해제될 때 헤더를 마무리한다
    let seconds = Double(_frames) / 16_000
    // 소리가 거의 없으면 껍데기 파일을 남기지 않는다.
    if seconds < 0.5 {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return (url, seconds, _frames * 2)
  }
}

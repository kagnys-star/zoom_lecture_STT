import Foundation
import AVFoundation

/// 저장해 둔 소리에서 한 구간만 잘라 WAV 로 돌려준다.
///
/// 표본을 모으려면 **그 자리 소리를 바로 들을 수 있어야 한다.**
/// 소리를 못 들으면 어느 쪽이 맞는지 판단할 근거가 없고, 그러면 표본이 아니라 짐작이 된다.
/// 실측에서 문맥 교정 모델이 전부 환각을 낸 이유도 정확히 이것이었다 — 모델은 못 듣는다.
///
/// 클립이 여러 개로 나뉘어 있어도(이어 적기) 파일 이름에 박힌 시작 초로 이어 붙인다.
enum AudioSlice {

  static let rate = 16_000.0
  /// 한 번에 잘라 줄 수 있는 최대 길이. 표본 확인용이라 길 이유가 없다.
  static let maxSeconds = 60.0

  /// 세션 타임라인 기준 `from`~`to` 초의 소리. 해당 구간에 저장된 소리가 없으면 nil.
  static func wav(dir: URL, from: Double, to: Double) -> Data? {
    let clips = AudioArchive.clips(in: dir)
    guard !clips.isEmpty else { return nil }

    let lo = max(0, from)
    let hi = min(lo + maxSeconds, to)
    guard hi > lo else { return nil }

    var samples: [Int16] = []
    for clip in clips {
      guard let file = try? AVAudioFile(forReading: clip.url) else { continue }
      let sr = file.fileFormat.sampleRate
      guard sr > 0 else { continue }

      let clipStart = clip.startOffset
      let clipEnd = clipStart + Double(file.length) / sr
      // 이 클립이 원하는 구간과 겹치지 않으면 건너뛴다.
      guard clipEnd > lo, clipStart < hi else { continue }

      let a = max(lo, clipStart) - clipStart      // 클립 안에서의 시작 초
      let b = min(hi, clipEnd) - clipStart
      guard b > a else { continue }

      file.framePosition = AVAudioFramePosition(a * sr)
      let frames = AVAudioFrameCount(((b - a) * sr).rounded())
      guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: frames),
            (try? file.read(into: buffer, frameCount: frames)) != nil
      else { continue }
      samples.append(contentsOf: int16(from: buffer))
    }
    guard !samples.isEmpty else { return nil }
    return encode(samples)
  }

  /// 그 구간에 실제로 소리가 있었는지 (peak dBFS). 소리가 하나도 안 남아 있으면 nil.
  ///
  /// **Whisper 환각을 잡는 데 쓴다.**
  /// Whisper 는 30초 덩어리를 받으면 끝까지 뭔가를 채워야 하는 구조라, 무음 구간에서도
  /// 문장을 지어낸다 — 학습 데이터에 유튜브 자막이 많아 「자막 제공 및 광고를 포함하고
  /// 있습니다」, 「감사합니다」 같은 게 튀어나온다. 반면 실시간 전사기는 음성 활동 검출이
  /// 구조적으로 들어 있어 침묵을 침묵으로 둔다. 그래서 이 오류는 Whisper 에서만 난다.
  ///
  /// 실측(6개 세션, Whisper 세그먼트 954개 전수 조사):
  /// ```
  /// −45 dBFS 미만       6개(0.63%) — 전부 환각
  /// 진짜 발화 하위 1%   −25.5 dBFS
  /// 최악의 환각         −52.1 dBFS      ← 사이에 27dB 가 비어 있다
  /// ```
  /// 겹치는 조각(이어 적기)을 **전부** 훑어 가장 큰 값을 취한다.
  /// 한 조각이라도 소리가 있었으면 그 시각엔 소리가 있었던 것이다 —
  /// 조각 하나만 보면 옛 조각의 무음 꼬리를 읽고 멀쩡한 발화를 무음으로 오판한다.
  static func peakDBFS(dir: URL, from: Double, to: Double) -> Double? {
    var loudest: Int16 = 0
    var found = false
    for clip in AudioArchive.clips(in: dir) {
      guard let file = try? AVAudioFile(forReading: clip.url) else { continue }
      let sr = file.fileFormat.sampleRate
      guard sr > 0 else { continue }
      let clipEnd = clip.startOffset + Double(file.length) / sr
      guard clipEnd > from, clip.startOffset < to else { continue }

      let a = max(from, clip.startOffset) - clip.startOffset
      let b = min(to, clipEnd) - clip.startOffset
      guard b > a else { continue }
      file.framePosition = AVAudioFramePosition(a * sr)
      let frames = AVAudioFrameCount(((b - a) * sr).rounded())
      guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
            (try? file.read(into: buffer, frameCount: frames)) != nil
      else { continue }
      found = true
      for v in int16(from: buffer) {
        let m = v == Int16.min ? Int16.max : abs(v)
        if m > loudest { loudest = m }
      }
    }
    guard found else { return nil }
    return 20 * log10(Double(max(loudest, 1)) / 32768)
  }

  /// 이 값보다 조용하면 **무음 의심**으로 표시한다. 지우지는 않는다.
  ///
  /// 표본이 환각 6건뿐이라 아직 지울 근거가 못 된다. 우선 표시만 해서
  /// 실제 수업 몇 번으로 오탐이 정말 0인지 확인한 뒤에 다음 단계를 정한다.
  static let quietCeiling: Double = -45

  /// 저장된 소리가 걸쳐 있는 구간인지. 화면에서 재생 버튼을 띄울지 정하는 데 쓴다.
  static func covers(dir: URL, from: Double, to: Double) -> Bool {
    AudioArchive.clips(in: dir).contains { clip in
      guard let file = try? AVAudioFile(forReading: clip.url),
            file.fileFormat.sampleRate > 0 else { return false }
      let end = clip.startOffset + Double(file.length) / file.fileFormat.sampleRate
      return end > from && clip.startOffset < to
    }
  }

  // MARK: - 변환

  /// 읽기용 버퍼는 보통 Float32 로 온다. 둘 다 받아 Int16 으로 맞춘다.
  private static func int16(from buffer: AVAudioPCMBuffer) -> [Int16] {
    let n = Int(buffer.frameLength)
    guard n > 0 else { return [] }
    if let src = buffer.int16ChannelData {
      return Array(UnsafeBufferPointer(start: src[0], count: n))
    }
    guard let src = buffer.floatChannelData else { return [] }
    return (0..<n).map { i in
      let v = max(-1, min(1, src[0][i]))
      return Int16(v * 32767)
    }
  }

  /// 최소한의 44바이트 WAV 머리. 브라우저 `<audio>` 가 바로 재생한다.
  private static func encode(_ samples: [Int16]) -> Data {
    let bytes = samples.count * 2
    var out = Data(capacity: 44 + bytes)

    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

    out.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + bytes))
    out.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)                       // fmt 청크 길이
    u16(1)                        // PCM
    u16(1)                        // 모노
    u32(UInt32(rate))
    u32(UInt32(rate) * 2)         // 바이트/초
    u16(2)                        // 블록 정렬
    u16(16)                       // 비트 깊이
    out.append(contentsOf: Array("data".utf8))
    u32(UInt32(bytes))
    samples.withUnsafeBufferPointer { out.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
    return out
  }
}

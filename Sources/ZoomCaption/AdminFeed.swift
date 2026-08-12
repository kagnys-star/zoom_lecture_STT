import AVFoundation
import Foundation

/// 관리자 모드 — 오디오를 **파일에서** 흘려 넣어 전체 경로를 시험한다.
///
/// 왜 필요한가.
/// 이 앱은 Zoom 이 실제로 소리를 내야만 아무것도 확인할 수 없다. 그래서 고칠 때마다
/// "수업이 있어야 알 수 있다" 가 되어, 실제로 여러 번 **고쳤다고 보고했는데 확인이 안 된 채**
/// 넘어갔다. 저장된 WAV 를 같은 파이프라인에 넣으면 그 고리를 끊을 수 있다.
///
/// 소리 장치를 타지 않으므로 재생 없이, 실시간보다 빠르게 돌릴 수 있다.
final class AdminFeed {

  /// 지금 돌고 있는 되먹임. 하나만 돈다.
  private var task: Task<Void, Never>?
  private(set) var isRunning = false
  private(set) var note = ""

  /// - Parameters:
  ///   - url: 16kHz mono WAV 가 아니어도 된다. AVAudioFile 이 알아서 읽는다.
  ///   - speed: 1.0 이면 실시간, 4.0 이면 4배속. 전사기가 못 따라오면 낮춘다.
  ///   - onBuffer: 실제 탭과 **같은 닫힘**을 받는다. 그래야 같은 경로를 시험한 게 된다.
  func start(url: URL, speed: Double,
             onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
             onFinish: @escaping @Sendable (String) -> Void) throws {
    stop()
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let total = file.length
    guard total > 0 else { throw AdminFeedError.empty }

    // 0.2초씩 끊어 보낸다. 탭이 주는 덩어리 크기와 비슷하게 맞춘 것이다.
    let frames = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.2)))
    let seconds = Double(total) / format.sampleRate
    isRunning = true
    note = "\(url.lastPathComponent) — \(String(format: "%.0f", seconds))초, \(String(format: "%.1f", speed))배속"
    log("관리자 되먹임 시작: \(note)")

    task = Task.detached(priority: .userInitiated) { [weak self] in
      var sent: AVAudioFramePosition = 0
      defer {
        Task { @MainActor in
          self?.isRunning = false
        }
      }
      while !Task.isCancelled, sent < total {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
        do { try file.read(into: buf, frameCount: frames) } catch {
          logError("관리자 되먹임 읽기 실패: \(error.localizedDescription)")
          break
        }
        guard buf.frameLength > 0 else { break }
        sent += AVAudioFramePosition(buf.frameLength)
        onBuffer(buf)
        // 실시간보다 빠르게 밀어 넣으면 전사기가 큐를 쌓는다. 배속만큼만 줄인다.
        let chunk = Double(buf.frameLength) / format.sampleRate
        try? await Task.sleep(for: .milliseconds(Int(chunk / max(speed, 0.1) * 1000)))
      }
      let done = Task.isCancelled ? "중단됨" : "끝까지 보냄"
      log("관리자 되먹임 \(done) — \(sent)/\(total) 프레임")
      onFinish(done)
    }
  }

  func stop() {
    task?.cancel()
    task = nil
    isRunning = false
  }

  enum AdminFeedError: LocalizedError {
    case empty
    var errorDescription: String? { "그 소리 파일은 비어 있습니다." }
  }
}

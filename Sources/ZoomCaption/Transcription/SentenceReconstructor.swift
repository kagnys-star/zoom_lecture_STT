import Foundation

/// Whisper 는 한 청크(30초)를 통째로 whisper.cpp 에 넘기고, 그 안에서 자기 나름의 쉬는
/// 지점마다 "줄"(Line)을 끊어서 준다. 근데 이 줄 하나가 항상 문장 하나는 아니다 —
/// 문장 2개가 붙어서 나올 때도 있고("그래서 생성자 관점에서 주입하는 거예요. 그래서
/// 우리가 생성할 때…"), 반대로 문장 하나가 줄 경계에서 잘려 다음 줄로 넘어갈 때도 있다.
///
/// 그래서 원문을 그대로 화면에 뿌리지 않고, 마침표(.?!) 기준으로 다시 쪼갠다 — 그래야
/// `Paragraph`(NLContextualEmbedding) 벡터 하나가 정확히 문장 하나만 대표하게 되고,
/// 화면에도 문장 단위로 깔끔하게 보인다. 마침표 없이 쉼표로만 길게 이어 말하는
/// 화자도 있어서(아래 `commaFallbackCharLimit` 참고), 그럴 땐 쉼표도 보조 경계로 쓴다.
///
/// **줄 하나에 문장이 여러 개 온전히 들어있으면 다음 줄을 기다릴 필요가 없다** — 그
/// 자리에서 바로 다 쪼개서 즉시 내보낸다. 기다리는 건 딱 "문장이 줄 경계에서 잘린
/// 꼬리"뿐이다 — 그 꼬리는 다음 줄이 와서 마침표가 나올 때까지 `pending` 에 남는다.
/// 대부분의 whisper 청크에 줄이 여러 개 들어있으므로(WhisperLive.onLines 가 청크 하나의
/// 결과를 통째로 준다), 실제로 다음 청크(최대 90초+)를 기다려야 하는 건 청크의 **마지막
/// 줄** 정도뿐이다 — 예전엔 마지막 3줄(windowRadius)이 다 기다렸다.
///
/// **시각은 근사치다.** Whisper 결과에는 낱말별 시각이 없다(`Segment.words` 는 Apple
/// 실시간 전용). 그래서 원본 줄의 [start, end] 구간을 글자 수 비율로 나눠 문장의
/// 시작·끝 시각을 추정한다 — 말하는 속도가 균일하지 않으면 어긋나지만, 줄 하나의 시각을
/// 문장 여러 개가 통째로 나눠 쓰는 것보다는 낫다.
final class SentenceReconstructor: @unchecked Sendable {
  private struct Piece {
    var start: Double
    var end: Double
    var text: String
  }

  private let lock = NSLock()
  /// 마침표를 아직 못 찾아 확정 못 한 조각들. 순서대로 이어붙이면 지금까지 쌓인
  /// 미완성 문장이 된다.
  private var pending: [Piece] = []

  /// 대기 글자 수가 이걸 넘으면 마침표 없이도 강제로 확정한다 — VADBoundary의
  /// maxSpeechSeconds 와 같은 발상의 안전장치. 실제 문장(20~80자 대)보다 훨씬 크게
  /// 잡아서, 정상적인 문장은 절대 여기 안 걸리게 한다.
  private static let forceFlushCharLimit = 400

  /// 마침표를 아직 못 찾았어도, 대기 글자 수가 이걸 넘으면 쉼표를 경계로 받아들인다.
  ///
  /// 실측(2026-08-25 라이브 강의): 화자가 5분 가까이 마침표 없이 쉼표로만 쭉 이어
  /// 말해서, "문장"이 578자·105초짜리 한 덩어리로 뭉쳐 나왔다 — Whisper 쪽 화면이
  /// 그동안 거의 비어 보이는 사고로 이어졌다(실시간 쪽은 정상, 소리도 정상이었다).
  /// 정상 문장(20~80자 대)보다는 크게 잡아 마침표로 끝나는 보통 문장엔 전혀 영향이
  /// 없게 하면서도, forceFlushCharLimit(400) 까지 가서 뭉텅이로 풀리기 전에 쉼표
  /// 자리에서 한 번은 끊어 화면에 더 자주, 더 작은 단위로 나오게 한다.
  private static let commaFallbackCharLimit = 150

  /// 새 Whisper 줄들이 도착했을 때 부른다. 확정된 문장들을 시간순으로 반환한다 —
  /// 마침표로 안 끝난 꼬리는 내부 버퍼에 남기고 다음 호출(또는 `finalize()`)을 기다린다.
  func reconstruct(_ lines: [WhisperLive.Line]) -> [WhisperLive.Line] {
    guard !lines.isEmpty else { return [] }
    return lock.withLock {
      var results: [WhisperLive.Line] = []

      for line in lines {
        var piece = Piece(start: line.start, end: line.end, text: line.text)
        while true {
          guard !piece.text.isEmpty else { break }
          let pendingLen = pending.reduce(0) { $0 + $1.text.count }
          let acceptComma = pendingLen + piece.text.count > Self.commaFallbackCharLimit
          guard let markIndex = piece.text.firstIndex(where: {
            $0 == "." || $0 == "?" || $0 == "!" || (acceptComma && $0 == ",")
          }) else {
            pending.append(piece)
            break
          }
          let cut = piece.text.index(after: markIndex)
          let head = String(piece.text[piece.text.startIndex..<cut])
          let charsToMark = piece.text.distance(from: piece.text.startIndex, to: cut)
          let frac = Double(charsToMark) / Double(max(piece.text.count, 1))
          let markTime = piece.start + (piece.end - piece.start) * frac

          let sentenceStart = pending.first?.start ?? piece.start
          let sentenceText = (pending.map(\.text) + [head])
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          pending.removeAll()
          if sentenceText.count >= 2 {
            results.append(WhisperLive.Line(start: sentenceStart, end: markTime, text: sentenceText))
          }

          let rest = String(piece.text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !rest.isEmpty else { break }
          // 한 줄 안에 문장이 더 있을 수 있으니, 남은 부분을 새 조각 삼아 계속 훑는다.
          // 시작 시각은 방금 문장이 끝난 지점을 이어받는다.
          piece = Piece(start: markTime, end: piece.end, text: rest)
        }
      }

      // 마침표 없이 너무 오래 쌓이면(드묾) 강제로 확정한다 — 계속 기다리기만 하면
      // 화면에 영영 안 나오는 줄이 생긴다.
      let pendingLen = pending.reduce(0) { $0 + $1.text.count }
      if pendingLen > Self.forceFlushCharLimit, let first = pending.first, let last = pending.last {
        let text = pending.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        pending.removeAll()
        if !text.isEmpty {
          results.append(WhisperLive.Line(start: first.start, end: last.end, text: text))
        }
      }

      return results
    }
  }

  /// 수업이 끝나 더 이상 줄이 안 올 때 마지막으로 부른다. 마침표를 못 찾았어도 남은
  /// 꼬리를 그대로 확정해서 돌려준다 — 안 그러면 마지막 문장이 영영 화면에 안 나온다.
  func finalize() -> [WhisperLive.Line] {
    lock.withLock { drainPendingSentenceLocked() }
  }

  /// 녹음은 계속되지만 180초 무음으로 한 강의 단위가 끝났을 때 남은 꼬리를 확정한다.
  ///
  /// `finalize()`와 결과는 같지만 이름으로 수명주기 의미를 분리한다. 이 객체를 닫거나
  /// 재생성하지 않기 때문에 무음 뒤 새 Whisper 줄은 같은 재구성기에 정상적으로 들어온다.
  /// 이전 강의의 미완성 문장을 다음 강의 첫 문장과 이어 붙이지 않는 것이 이 메서드의
  /// 핵심이다. 호출부는 Whisper 작업 큐가 비었고 같은 무음이 유지됐는지 확인한 뒤 부른다.
  func flushPendingForLectureBoundary() -> [WhisperLive.Line] {
    lock.withLock { drainPendingSentenceLocked() }
  }

  /// `pending`을 읽고 비우는 공통 구현. 반드시 `lock`을 잡은 상태에서만 호출한다.
  /// 한 곳에서 비우도록 해야 정지 처리와 긴 무음 처리가 서로 다른 텍스트 결합 규칙을
  /// 갖게 되는 일을 막을 수 있다.
  private func drainPendingSentenceLocked() -> [WhisperLive.Line] {
    guard let firstPendingPiece = pending.first,
          let lastPendingPiece = pending.last
    else { return [] }

    let pendingSentenceText = pending.map(\.text)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    pending.removeAll()
    guard !pendingSentenceText.isEmpty else { return [] }
    return [WhisperLive.Line(start: firstPendingPiece.start,
                             end: lastPendingPiece.end,
                             text: pendingSentenceText)]
  }
}

import Foundation
import NaturalLanguage

/// Whisper 문장을 문단으로 묶는다. 텍스트는 한 글자도 안 바꾼다 — 문장이 어디서
/// 끊기는지만 판단해서 문단 번호를 매긴다. 그래서 원문 재작성이 필요 없고(환각 위험 없음),
/// 문장별 시각도 그대로라 SRT·시각 클릭 이동이 안 깨진다.
///
/// **문장 임베딩이 아니라 contextual embedding을 쓰는 이유.** 한국어 문장 단위 임베딩
/// (`NLEmbedding.sentenceEmbedding`)은 한국어를 지원하지 않는다(직접 테스트 — nil 리턴).
/// `NLContextualEmbedding`은 한국어를 지원하지만, Apple 문서가 "의미 유사도엔
/// `NLEmbedding`을 쓰라"고 권할 만큼 이 용도로 설계되진 않았다. 실제로 강의 문장 5쌍으로
/// 재보면 같은 문단(0.74)과 약한 화제전환(0.72)의 코사인 유사도 차이가 0.02밖에 안 난다 —
/// 고정 임계값 하나로는 못 가른다. 완전 무관한 문장(0.60)까지 가야 뚜렷이 갈렸다.
/// 그래서 절대값이 아니라 **주변 구간 평균 대비 상대적으로 떨어지는 지점**(TextTiling류)을
/// 경계로 본다.
enum Paragraph {
  // embedder 는 prepare() 가 도는 스레드(비동기 Task)와 vector() 가 도는 스레드
  // (WhisperLive 의 드레인 큐)가 서로 다르다. 락 없이 그냥 static var 로 두면
  // Swift 가 막아주지 않는 데이터 경합이다 — 특히 Apple Silicon(ARM64)은 메모리 순서가
  // 느슨해서, 한쪽 스레드가 embedder 를 다 쓰기 전에 다른 스레드가 절반만 반영된 값을
  // 볼 수 있다. isReady 를 따로 안 두고 embedder != nil 로만 판단하는 것도 같은 이유 —
  // 두 변수를 따로 두면 그 사이에서도 경합이 생긴다.
  private static let lock = NSLock()
  private static var embedder: NLContextualEmbedding?
  static var isReady: Bool { lock.withLock { embedder != nil } }

  /// 앱 시작 시가 아니라 Whisper 재전사를 켤 때 한 번 부른다 — Whisper 를 안 쓰면
  /// 문단화도 의미가 없어 모델을 실을 이유가 없다. 로드가 늦어도 자막 자체는 안 막힌다,
  /// 그동안은 `regroupParagraphs` 가 `isReady == false` 로 조용히 건너뛴다.
  static func prepare() async {
    guard !isReady else { return }
    guard let e = NLContextualEmbedding(language: .korean) else {
      Logger.shared.log(.warn, "문단화 — 이 기기에서 한국어 contextual embedding 을 못 찾았습니다.")
      return
    }
    guard (try? await e.requestAssets()) == .available else {
      Logger.shared.log(.warn, "문단화 — 모델 에셋을 받지 못했습니다. 자막은 문장 단위로 그대로 나갑니다.")
      return
    }
    guard (try? e.load()) != nil else {
      Logger.shared.log(.warn, "문단화 — 모델 로드에 실패했습니다.")
      return
    }
    // await 를 넘어온 뒤, 다 준비된 e 를 마지막에 딱 한 번만 락 안에서 publish 한다.
    lock.withLock { embedder = e }
  }

  /// 문장 하나를 512차원 벡터 하나로 뭉친다(subword 토큰 벡터의 평균 — 문서가 권하는
  /// 풀링 방법 중 하나). 실패하면 nil — 호출부는 그 문장을 그냥 건너뛴다.
  static func vector(_ text: String) -> [Double]? {
    guard let e = lock.withLock({ embedder }), !text.isEmpty,
          let r = try? e.embeddingResult(for: text, language: .korean) else { return nil }
    var sum = [Double](repeating: 0, count: e.dimension)
    var n = 0
    r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
      for i in 0..<vec.count { sum[i] += vec[i] }
      n += 1
      return true
    }
    guard n > 0 else { return nil }
    return sum.map { $0 / Double(n) }
  }

  /// 코사인 거리(1 - 유사도)가 아니라 유사도 자체(-1~1, 보통은 0~1)를 돌려준다 —
  /// 호출부가 "높을수록 비슷하다"로 바로 비교할 수 있게.
  private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let denom = na.squareRoot() * nb.squareRoot()
    return denom > 0 ? dot / denom : 0
  }

  /// 문단을 가르는 최소 낙폭. 실측(위 주석)에서 같은 문단·약한 화제전환 사이 격차가
  /// 0.02뿐이라 낮게 잡아 뚜렷한 전환만 끊는다 — 못 갈라서 문단이 좀 길어지는 게,
  /// 잘못 갈라서 설명 하나가 두 문단으로 쪼개지는 것보다 낫다. 아직 실제 강의로
  /// 검증 전인 초기값이라 나중에 눈으로 보면서 조정이 필요하다.
  static let boundaryMargin = 0.08
  /// 경계 판정에 좌우로 몇 문장까지 문맥으로 볼지.
  static let windowRadius = 3

  /// i번째 문장 앞에 문단 경계를 둘지 판정한다. i번째가 판정에 필요한 문맥
  /// (`windowRadius`개)을 아직 못 가졌으면(문장이 그만큼 안 쌓였으면) 호출부가 아예
  /// 부르지 말아야 한다 — 그래야 나중에 문맥이 쌓인 뒤 판정이 뒤집혀 이미 보여준
  /// 문단이 재배치되는 일이 없다.
  static func isBoundary(before i: Int, vectors: [[Double]?]) -> Bool {
    guard i >= 1, i < vectors.count else { return false }
    func sim(_ gap: Int) -> Double? {
      guard gap >= 0, gap < vectors.count - 1,
            let a = vectors[gap], let b = vectors[gap + 1] else { return nil }
      return cosine(a, b)
    }
    let gap = i - 1
    guard let s = sim(gap) else { return false }
    let lo = max(0, gap - windowRadius), hi = min(vectors.count - 2, gap + windowRadius)
    let neighbors = (lo...hi).compactMap { $0 == gap ? nil : sim($0) }
    guard !neighbors.isEmpty else { return false }
    let avg = neighbors.reduce(0, +) / Double(neighbors.count)
    return (avg - s) >= boundaryMargin
  }
}

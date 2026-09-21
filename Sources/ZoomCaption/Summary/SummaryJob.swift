import Foundation

/// 진행 중인 로컬 요약 하나를 통째로 소유한다.
///
/// 예전에는 `isSummarizing`(선점), `summaryGeneration`(결과 유효성), 익명 `Task`(실행)가
/// 따로 놀았다. 해제 경로가 `defer`·성공·실패 세 갈래로 갈라져 있고 셋 다
/// `summaryGeneration == generation`을 조건으로 걸어서, generation이 진행 중에 한 번이라도
/// 바뀌면 **어느 경로도 플래그를 끄지 못해** 앱이 "요약 중"에 영구히 갇혔다. 그러면 세션
/// 열기·새 세션·녹음 시작이 앱을 다시 켜기 전까지 전부 막힌다. 강의 직전에 이게 터지면
/// 그날 녹음을 통째로 놓친다.
///
/// 하나의 객체가 수명을 쥐면 해제 지점이 `defer` 한 곳으로 줄어 그 상태가 성립할 수 없다.
/// 덤으로 취소가 "결과를 나중에 버리기"가 아니라 진짜 취소가 된다 — `Task.cancel()`은
/// 진행 중인 `URLSession` 요청까지 끊어서, 버릴 결과를 위해 8B 모델이 몇 분 더 도는 낭비를
/// 없앤다.
final class SummaryJob: @unchecked Sendable {
  /// 요약을 시작한 시점의 세션 폴더.
  ///
  /// 끝날 때 이 값이 현재 세션과 같은지 확인한다. 예전의 generation 비교는 "그 사이 다른
  /// 요청이 있었는가"를 셌을 뿐, 정작 막으려던 **결과가 엉뚱한 세션에 저장되는 일**을
  /// 간접적으로만 가리켰다. 지키려는 대상을 직접 비교하는 편이 조건 하나가 어긋나도
  /// 틀린 곳에 쓰지 않는다.
  let sessionDir: URL?
  let startedAt = Date()

  private let lock = NSLock()
  private var runningTask: Task<Void, Never>?
  private var completedCalls = 0
  private var totalCalls = 0

  init(sessionDir: URL?) {
    self.sessionDir = sessionDir
  }

  /// `Task`의 본문이 이 객체를 참조해야 해서 생성 뒤에 붙인다. 붙이기 전에 취소가
  /// 들어와도 잃어버리지 않도록, 이미 취소를 받았으면 붙이는 즉시 끊는다.
  private var cancelRequested = false

  func attach(_ task: Task<Void, Never>) {
    let shouldCancelImmediately = lock.withLock { () -> Bool in
      runningTask = task
      return cancelRequested
    }
    if shouldCancelImmediately { task.cancel() }
  }

  func cancel() {
    let task = lock.withLock { () -> Task<Void, Never>? in
      cancelRequested = true
      return runningTask
    }
    task?.cancel()
  }

  /// 새로고침한 브라우저도 진행률을 복원할 수 있도록 마지막 값을 들고 있는다.
  /// SSE 진행 이벤트는 `durable: false`라 재접속하면 사라지기 때문이다.
  func recordProgress(completed: Int, total: Int) {
    lock.withLock {
      completedCalls = completed
      totalCalls = total
    }
  }

  var progress: (completed: Int, total: Int) {
    lock.withLock { (completedCalls, totalCalls) }
  }
}

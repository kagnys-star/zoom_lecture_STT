# Zoom 정상 무음이 캡처 장애 팝업으로 표시되는 문제 분석 보고서

작성일: 2026-09-09
대상 브랜치: `feature/whisper-vad-paragraphs`
분석 대상 커밋: `64046db` 이후 현재 코드
분석 대상 로그: `~/Library/Logs/ZoomCaption/zoomcaption-2026-09-09.log`

## 1. 결론

이번 팝업은 오디오가 실제로 들어오지 않는 정상 무음 상황을 **캡처 장치 고장이나 권한 문제로 잘못 분류한 오탐**이다.

30초 무음 검출 자체는 정상적으로 작동했다. 문제는 그다음 판정이다. 현재 코드는 Zoom 프로세스의 `kAudioProcessPropertyIsRunningOutput` 값이 참이면 “Zoom은 지금 실제 소리를 내고 있다”고 간주한다. 그러나 Apple의 정의에서 이 값은 **프로세스가 출력 I/O를 실행 중이고 활성 출력 스트림이 하나 이상 있음**을 뜻한다. 그 스트림에 사람이 들을 수 있는 non-zero PCM 샘플이 존재한다는 뜻이 아니다.

Zoom은 회의에 연결되어 있는 동안 발표자가 말하지 않아도 출력 I/O와 출력 스트림을 계속 열어 둘 수 있다. 따라서 다음 두 조건이 동시에 성립한다.

```text
Zoom 출력 I/O는 활성 상태                  true
최근 30초간 탭에서 받은 non-zero 샘플      없음
```

현재 구현은 이 조합을 무조건 “Zoom은 소리를 내는데 ZoomCaption만 못 듣는다”로 바꿔 빨간 무음 배너를 띄운다. 하지만 실제 의미는 “Zoom 출력 스트림은 열려 있으나 현재 PCM은 조용하다”일 수 있다. 사용자가 설명한 당시 상황과 로그가 정확히 이 경우에 해당한다.

따라서 해결의 핵심은 시간 기준을 30초에서 더 길게 바꾸는 것이 아니다. 다음 세 상태를 분리해야 한다.

1. 오디오 콜백 자체가 계속 도착하는가
2. 도착한 버퍼에 audible sample이 있는가
3. Zoom 프로세스와 선택한 캡처 경로가 아직 유효한가

정상 무음은 2번만 거짓이다. 실제 캡처 장애는 1번 또는 3번이 거짓이거나, 사용자가 Zoom 소리를 실제로 듣고 있다는 별도 증거가 있는데 2번만 계속 거짓인 경우다.

## 2. 로그에서 확인한 사건 순서

실사용 세션의 관련 로그는 다음과 같다.

| 시각 | 로그 | 해석 |
|---|---|---|
| 10:05:17.876 | `시작 요청 — Zoom 수업` | 이어 적기 시작 |
| 10:05:17.944 | `녹음 시작 — Zoom 수업` | Core Audio 탭 정상 시작 |
| 10:52:59.276 | `chunk_0093.wav` Whisper 실행 | 그전까지 오디오 저장·Whisper 처리 진행 |
| 10:53:29.964 | `Zoom은 소리를 내고 있는데 이 앱에는 들리지 않습니다` | 문제의 오탐 배너 발생 |
| 10:54:21.263 | `조용한 구간이라 Whisper에 넘기지 않습니다 (피크 0, 약 79초)` | 마지막 약 79초가 실제 zero PCM이었음 |
| 10:54:21.263 | `소리 저장 완료 — 2941초` | 탭과 저장 파이프라인은 정지 요청까지 살아 있었음 |

마지막 79초 무음은 대략 10:53:02부터 시작한 것으로 계산된다. 30초 감시 기준과 20초 watchdog 주기를 거쳐 10:53:29에 경고한 흐름이 코드와 일치한다.

중요한 점은 `AudioArchive`가 마지막 구간을 **피크 0**이라고 기록했다는 것이다. 현재 무음 판정 임계값 `1e-5`보다 단지 조금 작은 음성이 들어온 것이 아니라, 표본에서 관찰된 최고값 자체가 0이었다. 따라서 이번 사건의 직접 원인은 음량 임계값이 너무 높아서 말소리를 놓친 것이 아니다.

## 3. 현재 코드가 오탐을 만드는 과정

### 3.1 오디오 활동 판정

`AudioActivityClock.observe(...)`는 들어온 버퍼에서 절댓값이 `1e-5`보다 큰 샘플을 하나라도 찾으면 `lastNonSilentAt`을 갱신한다.

```swift
if absoluteLevel > 1e-5 {
  containsAudibleSample = true
}
```

최근 30초 동안 이 시각이 갱신되지 않으면 `isHearingSound`가 거짓이 된다.

```swift
static let recentSoundWindow: TimeInterval = 30

var isHearingSound: Bool {
  (silenceDuration ?? .infinity) < Self.recentSoundWindow
}
```

여기까지는 “최근 30초간 탭 버퍼에 non-zero 오디오가 없었다”는 사실만 판정하므로 이번 로그와 일치한다.

### 3.2 Zoom 상태의 잘못된 해석

문제는 `CoreAudioInfo.isPlaying(...)`이다.

```swift
static func isPlaying(_ audioProcess: AudioProcessInfo) -> Bool {
  var propertyAddress = sysAddr(kAudioProcessPropertyIsRunningOutput)
  var isRunningOutput: UInt32 = 0
  // ...
  return propertyReadSucceeded && isRunningOutput != 0
}
```

함수 이름과 주석은 “지금 실제로 소리를 내보내는지”라고 설명하지만, 읽는 속성의 실제 의미는 “출력 I/O가 실행 중이고 활성 출력 스트림이 있는지”다. 활성 스트림이 zero-filled buffer를 보내는 정상 무음도 참이다.

그 결과 watchdog은 다음과 같이 잘못 추론한다.

```text
최근 30초 audible sample 없음
        +
Zoom hasActiveOutputIO == true
        ↓ 잘못된 추론
Zoom은 실제 소리를 내는데 탭만 고장남
        ↓
권한 확인 또는 재시작 팝업
```

실제 가능한 해석은 두 가지다.

```text
A. Zoom 출력 I/O는 열려 있고 현재 회의가 조용함
B. Zoom 출력 I/O는 열려 있고 tap이 고장 나 zero buffer를 전달함
```

현재 수집하는 신호만으로 A와 B를 자동 구별할 수 없다. 그런데 코드는 항상 B라고 단정한다.

### 3.3 UI도 잘못된 전제를 반복함

웹 UI의 status event 처리 주석은 서버가 “확실한 문제”만 보낸다고 가정한다.

```javascript
// Zoom 은 소리를 내는데 우리만 못 듣는, 확실한 문제일 때만 뜬다.
```

서버가 사용하는 `kAudioProcessPropertyIsRunningOutput`은 audible output을 보장하지 않으므로 이 주석과 실제 동작이 일치하지 않는다. UI는 서버가 보낸 `silent: true`를 그대로 빨간 배너로 표시하고 있어 프런트엔드 필터도 없다.

## 4. 이번 사건에서 가능성이 낮은 원인

### 4.1 시스템 오디오 권한 문제

해당 녹음은 10:05부터 약 48분 동안 정상적으로 오디오를 저장하고 Whisper 청크를 처리했다. 현재 실행의 `/api/diag`에서도 다시 non-zero 오디오가 들어오고 있다. 권한이 세션 마지막 79초에만 사라졌다가 자동 복구됐다는 증거는 없다.

따라서 팝업의 “시스템 설정에서 권한을 확인” 안내는 이번 사건과 맞지 않는다.

### 4.2 출력 장치 전환

문제 시각 주변에 `오디오 출력 장치 전환 감지` 로그가 없다. 장치 변경 60초 이내라면 다른 안내 문구를 선택하도록 구현되어 있는데, 실제로는 일반 권한 문구가 선택됐다.

따라서 현재 로그 기준으로는 이어폰 전환이 직접 원인이 아니다.

### 4.3 Whisper 또는 SpeechTranscriber 정지

팝업은 전사 결과가 아니라 `AudioActivityClock`과 Core Audio 프로세스 상태만으로 발생한다. Whisper 처리 성공 여부는 팝업 조건에 들어가지 않는다.

### 4.4 180초 강의 경계 구현

30초 캡처 경고와 180초 강의 종료 경계는 같은 마지막 audible 시각을 읽지만 서로 다른 분기다. 이번 경고는 180초가 되기 전에 발생했다. 180초 값을 조정해도 30초 팝업 오탐은 해결되지 않는다.

## 5. 별도로 발견한 로그 신뢰성 문제

당일 로그에는 실사용 앱과 관리자 되먹임 시험 프로세스가 같은 파일에 동시에 기록한 흔적이 있다.

```text
10:23:10 실사용 Whisper 로그 중간에
11:19:13 관리자 시험 세션 로그가 같은 줄로 삽입됨
```

11:19에 시작한 `긴_테스트2` 관리자 되먹임과 11:23의 `180초 연속 무음` 기록은 실사용 세션이 아니라 별도 시험 프로세스에서 나온 것이다. 따라서 11:23의 강의 종료 경계를 10:53 팝업의 연속 사건으로 해석하면 안 된다.

원인은 `Logger`가 날짜별 파일 이름 하나만 사용하고, 각 프로세스가 파일을 연 뒤 한 번 `seekToEnd()`한 독립 파일 오프셋으로 비동기 쓰기를 하기 때문이다. 프로세스 내부 직렬 queue는 같은 프로세스의 쓰기만 보호하며, 다른 ZoomCaption 프로세스와의 파일 쓰기를 조정하지 못한다.

이 문제는 팝업의 직접 원인은 아니지만, 향후 오디오 장애를 분석할 때 사건 순서를 훼손할 수 있으므로 함께 수정해야 한다.

## 6. 권장 해결 설계

### 6.1 속성 이름을 실제 의미에 맞게 변경

먼저 잘못된 추론이 다시 생기지 않도록 이름과 주석을 바로잡는다.

```swift
/// 프로세스가 출력 I/O를 실행하고 활성 출력 스트림을 가지고 있는지 확인한다.
/// true여도 스트림의 PCM 샘플이 0일 수 있으므로 “소리가 재생 중”이라는 뜻이 아니다.
static func hasActiveOutputIO(_ audioProcess: AudioProcessInfo) -> Bool

/// 현재 출력 I/O가 활성화된 프로세스의 번들 ID다.
/// 이름에 `playing`을 쓰면 audible audio로 오해하기 쉬우므로 사용하지 않는다.
static func activeOutputIOBundleIDs() -> [String]
```

이름만 바꿔도 `zoomPlaying`을 오류 근거로 사용하는 현재 코드가 의미상 어색해져 잘못된 조건을 발견하기 쉬워진다.

### 6.2 “버퍼 도착”과 “audible sample 도착”을 별도 시계로 관리

현재 `framesSeen`은 누적값이라 과거에 한 번이라도 콜백이 왔는지만 알려 준다. 지금 콜백이 멈췄는지는 판별할 수 없다. 다음 두 시각이 필요하다.

```swift
struct AudioCaptureActivitySnapshot: Sendable {
  /// 0으로만 채워진 버퍼라도 Core Audio 콜백이 도착할 때마다 갱신한다.
  let lastBufferArrivalInstant: ContinuousClock.Instant?

  /// 충분한 크기의 non-zero 오디오 창을 관찰했을 때만 갱신한다.
  let lastAudibleWindowInstant: ContinuousClock.Instant?

  let recentWindowRMSDBFS: Double
  let totalFramesReceived: Int64
}
```

두 값의 의미는 다음과 같다.

| 버퍼 도착 | audible sample | 해석 |
|---|---|---|
| 최근에도 도착 | 최근에도 있음 | 정상 수신 |
| 최근에도 도착 | 30초 이상 없음 | 정상 무음 또는 zero-buffer tap; 자동 단정 불가 |
| 수초간 없음 | 무관 | I/O callback 정지, 실제 캡처 장애 가능성 높음 |

경과 시간 측정은 시스템 시각 변경 영향을 받는 `Date`보다 `ContinuousClock` 같은 monotonic clock을 사용한다. 세션 기록에 표시할 wall-clock 시각이 필요한 경우에만 `Date`를 함께 저장한다.

### 6.3 캡처 경로 유효성을 독립적으로 검사

실제 장애로 확정할 수 있는 다음 조건을 별도로 추적한다.

- 선택한 Zoom `AudioObjectID`가 process object list에서 사라짐
- 선택한 출력 장치 UID 또는 stream이 사라짐
- aggregate device 또는 process tap 속성 읽기가 오류를 반환함
- IOProc callback이 설정된 짧은 제한 시간 동안 전혀 오지 않음
- 탭 재생성 중 오류가 발생함

이를 위해 이전 마이크 유입 분석에서 제안한 `AudioCaptureRouteSnapshot`을 사용한다.

```swift
struct AudioCaptureRouteSnapshot: Sendable {
  let selectedZoomProcessObjectIDs: [AudioObjectID]
  let selectedZoomBundleIDs: [String]
  let outputDeviceUID: String
  let outputStreamIndex: UInt
  let processTapObjectID: AudioObjectID
  let aggregateDeviceObjectID: AudioObjectID
}
```

이 스냅샷과 현재 Core Audio 목록을 watchdog이 비교하면 “조용함”이 아니라 “대상이 없어짐”을 정확히 탐지할 수 있다.

### 6.4 상태 머신으로 팝업 정책 분리

권장 상태는 다음과 같다.

```swift
enum AudioCaptureHealth: Equatable, Sendable {
  case receivingAudio
  case quiet
  case callbackStalled
  case zoomTargetLost
  case outputRouteChanged
  case tapInvalid
}
```

판정 순서는 오류처럼 확정할 수 있는 조건부터 검사한다.

```swift
func evaluateAudioCaptureHealth(
  activity: AudioCaptureActivitySnapshot,
  captureRouteIsValid: Bool,
  outputRouteChangedAfterTapCreation: Bool,
  currentInstant: ContinuousClock.Instant
) -> AudioCaptureHealth {
  // 선택했던 Zoom process나 tap object가 사라졌다면 실제 경로 장애다.
  guard captureRouteIsValid else { return .zoomTargetLost }

  // non-zero 여부와 무관하게 IOProc 콜백 자체가 멈춘 경우만 callback stall이다.
  guard activity.receivedBufferRecently(at: currentInstant) else {
    return .callbackStalled
  }

  // 장치 변경은 탭 재생성이 필요한 별도 상태로 다룬다.
  guard !outputRouteChangedAfterTapCreation else {
    return .outputRouteChanged
  }

  // 콜백과 경로가 정상이면 zero PCM만 들어와도 오류로 단정하지 않는다.
  return activity.receivedAudibleAudioRecently(at: currentInstant)
    ? .receivingAudio
    : .quiet
}
```

UI 정책은 다음처럼 바꾼다.

| 상태 | UI | 자동 조치 |
|---|---|---|
| `receivingAudio` | 배너 없음 | 없음 |
| `quiet` | 기본적으로 배너 없음. 필요하면 회색 상태 표시만 | 180초가 되면 기존 강의 경계 처리 |
| `callbackStalled` | 빨간 오류 배너 | 탭 전체 재생성 시도 |
| `zoomTargetLost` | 주황 안내 | Zoom 프로세스 재탐색 후 탭 재생성 |
| `outputRouteChanged` | 주황 안내 | 새 출력 UID/stream으로 탭 재생성 |
| `tapInvalid` | 빨간 오류 배너 | process tap과 aggregate device 전체 재생성 |

핵심은 `.quiet`에서 현재의 권한·재시작 팝업을 띄우지 않는 것이다.

### 6.5 정상 무음과 zero-buffer tap 장애를 다루는 방법

콜백은 계속 오지만 샘플이 모두 0인 상황만으로는 정상 무음과 tap 장애를 완전히 구분할 수 없다. `hasActiveOutputIO`도 이 구분을 제공하지 않는다. 따라서 다음 중 하나가 추가로 필요하다.

#### 방법 A: 사용자 확인을 결합한 오디오 검사

30초 무음 자체로 팝업을 띄우지 않고, 화면에 작은 “Zoom 소리가 실제로 들리는데 자막이 안 나오나요?” 검사 버튼을 제공한다. 사용자가 그렇다고 확인한 순간부터 3~5초 동안 탭 PCM이 계속 0이면 실제 캡처 실패로 승격한다.

이 방법은 자동 판정은 아니지만 발표자 침묵과 tap 실패를 가장 정직하게 구분한다.

#### 방법 B: 알려진 테스트 신호 사용

관리자 진단에서 Zoom 또는 선택한 출력 경로에 출처를 아는 테스트 음을 재생하고 process tap에서 해당 주파수/패턴을 찾는다. 테스트 신호가 실제로 생성됐다는 보장이 있는데 탭에서 검출되지 않으면 장애로 판정할 수 있다.

실제 수업 중 임의의 테스트음을 재생하면 방해가 되므로 자동 실행하면 안 되고, 명시적인 진단 버튼으로만 제공해야 한다.

#### 방법 C: 보수적인 자동 복구

장시간 zero buffer가 이어져도 오류 팝업 대신 탭을 조용히 재생성하는 방식은 위험하다. 정상 휴식 시간에도 재생성이 일어나고, 재생성 순간의 원격 첫 음성을 잃을 수 있다. 다음 조건을 추가할 때만 사용한다.

- 최근 출력 장치 전환이 있었음
- 선택한 Zoom process object가 교체됨
- tap/aggregate 속성 검사 실패
- callback heartbeat 중단

단순 30초 또는 180초 무음만으로는 재생성하지 않는다.

### 6.6 30초 경고와 180초 강의 경계를 분리 유지

180초 무음은 “캡처가 고장났다”는 진단이 아니라 “한 강의 단위가 끝났다”는 콘텐츠 정책이다. 녹음을 멈추지 않고 Whisper 꼬리와 문단을 닫는 현재 목적은 유지할 수 있다.

수정 후 동작은 다음과 같아야 한다.

```text
30초 실제 무음
  └─ 오류 팝업 없음

180초 실제 무음
  └─ 강의 종료 경계 기록
     녹음과 오디오 콜백은 계속 유지

도중에 소리 재개
  └─ 새 강의로 계속 기록
```

30초 값은 필요하다면 회색 상태 표시나 내부 진단 로그에만 사용한다. 빨간 장애 팝업의 기준으로 사용하지 않는다.

### 6.7 로그를 프로세스별로 분리

가장 단순하고 안전한 해결은 파일명에 PID를 포함하는 것이다.

```text
zoomcaption-2026-09-09-1977.log
zoomcaption-2026-09-09-29731.log
```

또는 한 파일을 유지해야 한다면 `O_APPEND`로 열고 한 로그 레코드를 한 번의 write로 쓰며 프로세스 간 잠금도 적용해야 한다. 이 앱은 실사용 앱, `--selftest`, 관리자 되먹임 시험이 동시에 실행될 수 있으므로 PID별 파일이 분석과 구현 모두 더 단순하다.

모든 오디오 상태 전환 로그에는 다음 필드를 넣는다.

```text
pid=1977 recordingGeneration=...
health=quiet
secondsSinceBuffer=0.01
secondsSinceAudible=31.4
recentRMSDBFS=-inf
zoomHasActiveOutputIO=true
captureRouteValid=true
outputDeviceUID=...
```

이 정보가 있으면 다음 재현에서는 정상 무음과 callback stall을 로그만으로 구별할 수 있다.

## 7. 구현 우선순위

| 우선순위 | 변경 | 이유 |
|---|---|---|
| P0 | `isPlaying`을 `hasActiveOutputIO`로 변경 | 현재 오탐의 직접 원인인 의미 오류 제거 |
| P0 | 정상 `.quiet`에서 빨간 팝업 제거 | 사용자가 겪은 증상 즉시 해결 |
| P0 | `lastBufferArrivalInstant` 추가 | callback이 실제로 멈췄는지 판별 |
| P1 | 캡처 경로 스냅샷과 유효성 검사 | process/route 소실을 실제 장애로 탐지 |
| P1 | 상태 머신 기반 UI 메시지 분리 | 정상 무음, 장치 변경, 경로 고장을 다른 안내로 표시 |
| P1 | PID별 로그 파일 | 동시 실행 로그 훼손 방지 |
| P2 | 명시적 오디오 검사 버튼 | zero-buffer tap과 실제 침묵을 확실히 구분 |

## 8. 시험 계획

### 단위 시험

시간과 Core Audio 객체를 직접 읽는 watchdog에서 판정 로직을 순수 함수로 분리하고 가짜 clock으로 시험한다.

1. 콜백이 계속 오고 audible sample만 31초 없음 → `.quiet`
2. 콜백이 5초 이상 없음 → `.callbackStalled`
3. 선택한 Zoom object가 사라짐 → `.zoomTargetLost`
4. 출력 UID 변경 → `.outputRouteChanged`
5. 무음 뒤 sample 재개 → `.receivingAudio`
6. `.quiet`에서는 빨간 `silentMessage` 이벤트가 생성되지 않음
7. `.callbackStalled`, `.tapInvalid`에서만 빨간 오류 이벤트 생성

### 관리자 모드 통합 시험

1. 60초 음성 + 120초 zero PCM 파일을 되먹인다.
   - 30초 이후 오류 팝업이 없어야 한다.
   - 전사기와 녹음 상태는 살아 있어야 한다.
2. 60초 음성 + 190초 zero PCM 파일을 되먹인다.
   - 180초에 강의 종료 경계가 정확히 한 번 생겨야 한다.
   - 오류 팝업은 없어야 한다.
3. 시험용 tap callback 전달을 의도적으로 중단한다.
   - 설정한 heartbeat 제한 안에 callback 장애 배너가 떠야 한다.
4. 출력 장치를 변경한다.
   - 장치 변경 상태가 표시되고 새 경로로 재생성되어야 한다.
5. 두 시험 프로세스를 동시에 실행한다.
   - 로그가 PID별로 분리되고 한 줄도 섞이지 않아야 한다.

### 실제 Zoom 시험

1. Zoom 회의 연결 상태에서 발표자가 1분간 침묵한다.
   - 빨간 팝업이 없어야 한다.
2. 침묵 뒤 발표자가 다시 말한다.
   - 재시작 없이 자막이 바로 이어져야 한다.
3. 3분 이상 휴식한다.
   - 강의 종료 표식만 생기고 캡처는 계속 유지되어야 한다.
4. Zoom 소리가 실제로 들리는 도중 tap callback을 시험적으로 차단한다.
   - 이때만 캡처 장애 배너가 떠야 한다.

## 9. 합격 기준

- Zoom 출력 스트림이 활성 상태여도 실제 PCM이 30초간 0이면 장애 팝업을 띄우지 않는다.
- callback heartbeat가 중단되거나 선택한 캡처 경로가 사라지면 원인별 오류를 표시한다.
- 180초 강의 경계 기능은 기존처럼 유지된다.
- 정상 무음 뒤 소리가 재개되면 정지·시작 없이 전사가 계속된다.
- 권한 문제라고 확인되지 않은 상황에 권한 확인 문구를 표시하지 않는다.
- 로그에서 PID, 녹음 세대, 버퍼 경과 시간, audible 경과 시간, 경로 상태를 확인할 수 있다.
- 실사용과 관리자 시험을 동시에 실행해도 로그 줄과 시간 순서가 훼손되지 않는다.

## 10. 최종 권고

이번 문제는 무음 시간을 늘려서 해결할 문제가 아니다. `kAudioProcessPropertyIsRunningOutput`을 audible audio 지표로 사용한 것이 구조적인 오류다.

가장 먼저 다음 세 가지를 함께 적용해야 한다.

1. `isPlaying`의 의미와 이름을 `hasActiveOutputIO`로 바로잡는다.
2. 콜백 heartbeat와 audible activity를 분리하고, 정상 무음에서는 빨간 팝업을 제거한다.
3. 캡처 경로 소실 또는 callback 중단처럼 확인 가능한 장애에만 오류 팝업을 사용한다.

그다음 캡처 경로 스냅샷, 자동 재연결, PID별 로그를 추가하면 실제 탭 장애가 발생했을 때도 정상 휴식과 혼동하지 않고 복구할 수 있다.

## 11. 참고 자료

- Apple, [AudioHardwareProcess.isRunningOutput](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/isrunningoutput) — 참은 “running I/O + active output stream”을 뜻한다.
- Apple, [kAudioProcessPropertyIsRunningOutput](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunningoutput)
- Apple, [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

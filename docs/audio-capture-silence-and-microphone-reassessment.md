# Zoom 무음 오탐과 로컬 마이크 혼입 재진단 보고서

작성일: 2026-09-09
대상 브랜치: `feature/whisper-vad-paragraphs`

이 문서는 프로젝트 브리핑, 현재 소스, 2026-09-09 실사용 로그를 함께 대조해 두 현상을 다시 진단한 결과다.

- Zoom이 조용한데 캡처 장애라고 판단하여 빨간 팝업을 띄우는 현상
- Zoom에서 마이크를 켰을 때 사용자의 음성이 강의 캡처에 들어오는 현상

기존의 다음 설계는 문제 원인이 아니며 그대로 보존해야 한다.

- SpeechTranscriber는 지연이 짧은 실시간 자막을 담당한다.
- Whisper는 약 60~90초 뒤 더 정확한 문장을 복원한다.
- 180초 무음은 하나의 강의가 끝났음을 기록하는 콘텐츠 경계다.
- 180초 경계는 `lastNonSilentAt` 절대 시각, Whisper 유휴 대기, 재검증 후 `volatile` 정리라는 현재 방식을 유지한다.
- 전처리·정규화·노이즈 필터는 이미 실제 음성 인식 결과를 악화시킨 것으로 검증되었으므로 해결책으로 다시 도입하지 않는다.

이 보고서는 기존 `zoom-silence-popup-false-positive-analysis.md`와
`zoom-microphone-capture-leak-analysis.md`의 결론을 프로젝트 전체 구조에 맞게 통합하고,
마이크 파형 제거 같은 전처리 제안을 제외한 최종 권고안이다.

## 1. 최종 결론

두 버그는 별개의 전사 문제가 아니라 캡처 계층에서 서로 다른 개념을 하나로 취급한 문제다.

현재 구현은 다음 세 가지를 명확히 구분하지 않는다.

1. **캡처 경로 생존 여부**: Core Audio 콜백이 계속 도착하고 있는가?
2. **콘텐츠 활동 여부**: 도착한 PCM 안에 실제로 0이 아닌 소리가 있는가?
3. **화자·출처 식별**: 그 소리가 원격 참가자, 로컬 마이크 되울림, 다른 Zoom 기능 중 어디에서 왔는가?

그 결과 같은 오해가 반대 방향으로 나타난다.

| 현상 | 현재 추론 | 실제로 알 수 있는 것 | 결과 |
|---|---|---|---|
| 무음 팝업 | Zoom 프로세스의 출력 I/O가 실행 중이므로 Zoom은 실제 소리를 내고 있다 | 출력 스트림이 활성 상태일 뿐, 샘플이 0인지 아닌지는 모른다 | 정상 침묵을 권한·탭 장애로 오탐 |
| 마이크 혼입 | Zoom 프로세스 출력이므로 모두 원격 강의 음성이다 | 지정한 Zoom 프로세스들의 모든 출력 스트림을 이미 하나로 섞은 PCM이다 | 로컬 음성이 그 출력에 나타나면 분리 불가 |

핵심 해결 방향은 **원본 PCM을 가공하는 것**이 아니라 **올바른 출처만 선택하고, 경로 건강 상태와 콘텐츠 무음을 별도로 관측하는 것**이다.

## 2. 현재 오디오 흐름

현재 실제 캡처 버퍼는 한 번 만들어진 뒤 다음 세 곳에 그대로 전달된다.

```text
SystemAudioTap
    │
    ├─ AudioActivityClock.observe   ← 30초 활동 판정과 180초 강의 경계
    ├─ TrackTranscriber.feed        ← 실시간 SpeechTranscriber
    └─ AudioArchive.write
             └─ WhisperLive         ← 60~90초 지연 재전사
```

따라서 마이크 음성이 `SystemAudioTap` 단계에서 이미 섞였다면 SpeechTranscriber와 Whisper 양쪽에 똑같이 들어간다. Whisper가 마이크를 새로 여는 구조도 아니고, 두 전사기가 서로의 오디오를 전달하는 구조도 아니다.

소스에는 현재 `AVAudioEngine.inputNode` 같은 직접 마이크 입력을 여는 코드가 없다. `Info.plist`의 `NSMicrophoneUsageDescription` 문구는 과거 기능의 흔적으로 보이며, 이것이 실제 마이크 캡처를 발생시키는 것은 아니다. 사용자의 목소리가 결과에 들어온다면 그 신호는 **Zoom이 자기 출력 경로에 내보낸 오디오를 Core Audio 탭이 받은 것**으로 보는 것이 현재 증거에 가장 잘 맞는다.

## 3. 무음 팝업 재진단

### 3.1 로그가 증명하는 사실

2026-09-09 실사용 세션의 관련 순서는 다음과 같다.

| 시각 | 로그 | 해석 |
|---|---|---|
| 10:05:17.944 | 녹음 시작 | 기존 세션 이어 적기 시작 |
| 10:52:59.276 | Whisper `chunk_0093.wav` 실행 | 그 전까지 정상 오디오와 재전사 진행 |
| 10:53:29.964 | “Zoom은 소리를 내는데 앱에는 들리지 않는다” 경고 | 약 30초 무음 조건 충족 |
| 10:54:21.263 | `피크 0, 약 79초`라 Whisper 전달 생략 | 실제 저장 PCM이 완전한 0이었음 |
| 10:54:21.263 | 2941초 오디오 저장 완료 | 탭과 아카이브는 세션 대부분 정상 작동 |

이 로그로 확인할 수 있는 것은 다음과 같다.

- 무음 판정 자체는 정상이다. 피크가 단순히 작았던 것이 아니라 정확히 `0`이었다.
- 임계값 `1e-5` 때문에 사람 목소리를 놓친 사례가 아니다.
- 약 48분간 정상 오디오가 들어온 같은 세션이므로, 시작부터 화면·시스템 오디오 권한이 없었던 상황과 맞지 않는다.
- Whisper 성공 여부는 팝업 조건에 포함되지 않으므로 Whisper 지연이나 VAD가 팝업 원인이 아니다.
- 180초 강의 경계에도 도달하기 전 발생했으므로 그 기능과도 무관하다.

즉 이번 사례는 **“무음이라고 인식한 것”이 오류가 아니라, 그 무음을 “캡처 장애”라고 해석한 것이 오류**다.

### 3.2 직접 원인: `isRunningOutput` 의미 오해

현재 `CoreAudioInfo.isPlaying`은 `kAudioProcessPropertyIsRunningOutput`을 읽는다. 코드 주석은 이를 “지금 실제로 소리를 내보내고 있는지”라고 설명하지만 Core Audio가 보장하는 의미는 다르다.

Apple 문서에서 `isRunningOutput`은 해당 프로세스가 I/O를 실행하고 하나 이상의 활성 출력 스트림을 가졌다는 뜻이다. 활성 스트림의 샘플이 실제 음성인지, 전부 0인지까지 알려주지 않는다.

Zoom은 회의 중 재생 경로를 열어 둔 채 발표자가 침묵해도 출력 I/O를 활성 상태로 유지할 수 있다. 이때 현재 코드는 다음 잘못된 추론을 한다.

```text
Zoom 출력 I/O 활성
    +
우리 PCM은 30초간 0
    ↓
“Zoom은 실제 소리를 내는데 앱이 못 받음”
    ↓
권한 또는 탭 장애 빨간 팝업
```

실제로는 다음 두 경우가 구분되지 않는다.

- 정상: Zoom 출력 경로는 열려 있지만 발표자가 침묵하여 0 PCM이 계속 들어옴
- 장애: Zoom에는 실제 원격 소리가 있지만 탭이 0 PCM만 전달하거나 콜백이 멈춤

`isRunningOutput` 하나만으로 두 경우를 나누는 것은 불가능하다.

### 3.3 현재 관측값의 추가 한계

`AudioActivityClock.framesSeen`은 녹음 시작 후 받은 프레임의 누적값이다. 한 번이라도 버퍼를 받으면 계속 0보다 크므로 다음 둘을 구분하지 못한다.

- 콜백은 정상적으로 계속 오고 있으며 내용만 0인 상태
- 어느 시점부터 Core Audio 콜백 자체가 완전히 멈춘 상태

또한 현재 180초 경계는 마지막 소리 시각만 본다. 만약 콜백이 실제로 죽어 버리면 시간은 계속 흐르므로 인프라 장애를 강의 종료 무음으로 오해할 수 있다. 180초 계산법을 바꿀 필요는 없지만, **경계를 적용하기 전에 캡처 콜백이 살아 있다는 조건을 추가**해야 한다.

## 4. 마이크 음성 혼입 재진단

### 4.1 직접 원인 후보 1: Zoom 프로세스의 모든 출력 스트림을 먼저 혼합

일반 모드의 현재 코드는 허용 목록과 일치하는 Zoom 프로세스의 `AudioObjectID`를 모아 다음 탭을 만든다.

```swift
CATapDescription(stereoMixdownOfProcesses: zoomAudioProcessObjectIDs)
```

이 초기화 방식은 지정한 프로세스들의 출력 스트림을 하나의 스테레오 신호로 혼합한다. 혼합이 끝난 버퍼에는 다음 정보가 남지 않는다.

- 어느 Zoom 프로세스에서 왔는지
- 어느 출력 장치와 스트림에서 왔는지
- 원격 참가자 음성인지 로컬 마이크 모니터링인지
- Zoom의 마이크 테스트·에코 기능인지
- 참가자 ID가 무엇인지

따라서 로컬 마이크 신호가 Zoom의 출력 스트림 중 하나에 나타나는 순간, 이후의 리샘플러·SpeechTranscriber·AudioArchive·Whisper는 그것을 원격 음성과 구분할 수 없다.

`desc.muteBehavior = .unmuted`도 마이크 제외 옵션이 아니다. 이것은 탭으로 캡처하는 동안 원래 출력이 하드웨어에서도 계속 들리게 할지를 정하는 설정이다.

### 4.2 직접 원인 후보 2: Zoom 대상을 못 찾으면 시스템 전체 캡처로 조용히 전환

현재는 녹음 시작 순간에 Zoom 대상 프로세스 배열이 비어 있으면 일반 모드에서도 다음 전역 탭으로 자동 전환한다.

```swift
CATapDescription(stereoGlobalTapButExcludeProcesses: [])
```

“Zoom보다 앱을 먼저 켜는 경우”를 허용하기 위한 동작이지만, 사용자는 Zoom 전용으로 녹음한다고 생각하는 동안 앱은 시스템 전체 출력을 캡처할 수 있다. 이는 마이크 되울림뿐 아니라 알림음, 브라우저, 미디어 플레이어 등 다른 소리까지 강의에 섞일 수 있는 더 큰 범위 오류다.

관측한 실사용 세션에서는 Zoom이 앱보다 먼저 실행된 정황이 있어 이번 마이크 사례가 반드시 전역 폴백 때문이라고 단정할 수는 없다. 그러나 시작 때 선택된 대상과 경로가 로그에 남지 않아 완전히 배제할 수도 없다. 이 폴백은 원인 여부와 무관하게 제거해야 할 위험한 동작이다.

### 4.3 아직 증명되지 않은 부분

현재 로그만으로는 로컬 마이크 신호가 다음 중 정확히 어디에 존재하는지 알 수 없다.

- `us.zoom.xos`의 원격 재생과 같은 출력 스트림
- `us.zoom.xos`의 별도 출력 스트림
- 다른 Zoom 헬퍼 프로세스의 출력
- Zoom 마이크 테스트나 에코·모니터 기능에서만 나타나는 출력
- 전역 폴백으로 잡힌 다른 시스템 출력

현재 실행 중인 프로세스에서 `us.zoom.xos`와 `us.zoom.caphost`가 관측됐지만, 기존 허용 목록에는 `caphost`가 없고 대신 Clips, Launcher, AudioDaemon이 포함돼 있다. 이름만 보고 새 헬퍼를 추가하거나 기존 헬퍼를 제거하면 안 된다. 각 프로세스·장치·스트림을 격리한 A/B 측정이 먼저다.

## 5. 권장 목표 구조

기존 하나의 `AudioActivityClock`에 캡처 건강 상태까지 맡기지 않고 책임을 분리한다. 다만 **A/B 진단 전에는 Zoom 경로 선택 컴포넌트의 최종 타입·이름·시그니처를 확정하지 않는다.** 아래의 `검증 후 결정할 캡처 경로`는 구현할 클래스 이름이 아니라 아직 열어 둬야 하는 설계 자리다.

```text
관리자 실제 탭 A/B 진단
  └─ 마이크 신호가 섞이는 process/device/stream 위치 확인
       └─ 검증 후 결정할 캡처 경로  ← 최종 시그니처 확정 금지
            └─ SystemAudioTap
                 ├─ AudioCaptureHeartbeat
                 │    └─ 콜백 도착 시각, 경로 세대, 중단 여부만 관측
                 ├─ AudioActivityClock
                 │    └─ 원본 PCM의 마지막 유효 소리 시각과 180초 경계 유지
                 ├─ SpeechTranscriber
                 └─ AudioArchive → WhisperLive

AudioCaptureHealthMonitor
  └─ 시작에 성공한 탭의 경로 정보 + heartbeat + 활동 시계로 UI 상태 결정
```

진단 결과와 무관하게 지금 확정해도 되는 것은 다음 세 가지뿐이다.

- 일반 모드에서 Zoom 대상을 찾지 못하면 시스템 전체 캡처로 폴백하지 않는다.
- 캡처 콜백 생존 여부와 PCM 콘텐츠 무음을 별도로 관측한다.
- SpeechTranscriber와 Whisper에는 선택된 경로의 가공하지 않은 동일 PCM을 전달한다.

다음 항목은 A/B 결과가 나오기 전까지 확정하지 않는다.

- `ZoomAudioRouteResolver` 같은 최종 클래스 이름과 공개 시그니처
- 특정 bundle ID가 항상 회의 오디오 담당이라는 가정
- `process + deviceUID + stream`이 최종 운영 경로라는 가정
- 장치 변경 시 자동 재연결이 가능한지, 명시적 재시작이 필요한지

### `AudioCaptureHeartbeat`

- 샘플 값과 무관하게 Core Audio 버퍼가 도착할 때마다 단조 증가 시각을 갱신한다.
- 시스템 시간이 바뀌어도 영향받지 않도록 새 건강 상태에는 `ContinuousClock.Instant`를 쓴다.
- “0 PCM이 계속 도착함”과 “콜백 자체가 끊김”을 구분한다.
- 녹음 세대 UUID와 캡처 경로 세대를 함께 보관하여 오래된 콜백이 새 녹음 상태를 갱신하지 못하게 한다.

### 기존 `AudioActivityClock`

- 샘플에서 실제 활동을 측정한다.
- 이미 검증된 `lastNonSilentAt` 기반 180초 계산을 유지한다.
- `volatile` 정리와 강의 종료 표시의 재검증 로직을 유지한다.
- 캡처 건강 상태가 `.quiet`일 때만 180초 강의 경계를 시작하도록 입구 조건만 보강한다.

### `AudioCaptureHealthMonitor`

UI가 사용할 상태를 명시적인 열거형으로 계산한다.

```swift
enum AudioCaptureHealth {
  case receivingAudio
  case quiet
  case callbackStalled
  case targetProcessLost
  case routeChanged
  case tapInvalid
}
```

상태별 의미와 UI는 다음이 적절하다.

| 상태 | 조건 | UI 정책 |
|---|---|---|
| `receivingAudio` | 콜백 최신 + 최근 30초 내 유효 소리 | 정상 |
| `quiet` | 콜백 최신 + 최근 30초간 샘플이 0에 가까움 | 빨간 팝업 금지; 필요하면 회색 “현재 무음” 표시 |
| `callbackStalled` | 경로는 존재하지만 최근 버퍼가 오지 않음 | 빨간 경고 및 안전한 재연결 안내 |
| `targetProcessLost` | 대상 PID/AudioObject가 사라짐 | 주황 경고, Zoom 재탐색 |
| `routeChanged` | Zoom 사용 장치/스트림이 달라짐 | 주황 경고 또는 자동 재연결 진행 표시 |
| `tapInvalid` | HAL 오류나 탭 재생성 실패 | 빨간 오류와 구체적 OSStatus |

중요한 정책은 **`quiet`만으로 권한 오류를 띄우지 않는 것**이다. 앱은 PCM만 보고 발표자가 말하고 있는지를 알 수 없다.

`AudioCaptureHealth`는 탭 시작에 성공한 뒤의 런타임 상태다. Zoom을 아직 찾지 못한 상태는 현재 구조에서 여기에 넣지 않고, 녹음이 시작되지 않은 구체적인 시작 오류로 처리한다. 그래야 `running`이면서 실제 탭은 없는 모순된 상태를 만들지 않는다.

## 6. 구체적인 구현 방법

### 6.1 캡처 모드를 Bool 대신 명시적인 타입으로 바꾼다

현재 `start(zoomOnly: Bool)`은 `false`가 관리자 시스템 캡처인지, Zoom 탐색 실패에 따른 폴백인지 호출부를 보지 않으면 알기 어렵다.

```swift
enum AudioCaptureScope {
  /// 실사용 모드. Zoom 후보를 찾지 못하면 전역 폴백 없이 즉시 오류를 던진다.
  case zoomMeetingOutput

  /// 격리된 관리자 검증에서만 사용한다. 시스템 전체 오디오가 의도임을 명시한다.
  case administratorSystemOutput
}
```

이 타입은 **캡처 범위와 실패 정책만 표현**한다. `zoomMeetingOutput`이 Zoom을 기다리거나 재시도한다는 뜻은 아니다. 현재 `start()` 수명주기를 유지하는 1차 수정에서는 Zoom 후보가 없으면 `zoomAudioProcessUnavailable` 같은 구체적인 오류를 즉시 던져 `/api/start`가 잡아 둔 `running`과 `starting`을 기존 catch에서 되돌리게 한다.

의미 있는 변수명도 함께 적용한다.

- `targets` → `zoomAudioProcessObjectIDs`
- `desc` → `captureTapDescription`
- `outUID` → `selectedOutputDeviceUID`
- `playing` → `processesWithActiveOutputIO`
- `zoomPlaying` → `zoomHasActiveOutputIO`

### 6.2 실사용 전역 폴백은 제거하되, 현재 `start()`에서는 즉시 실패한다

현재 `/api/start`는 작업을 시작하기 전에 `running = true`, `starting = true`를 먼저 설정한다. `ZoomCaptionApp.start()`는 그 뒤 다음 자원을 순서대로 켠다.

```text
분석 모델 준비
  → 세션 폴더와 store.beginRecording()
  → TrackTranscriber
  → AudioArchive
  → SentenceReconstructor / WhisperLive
  → 마지막에 SystemAudioTap.start()
```

또한 `/api/stop`은 `starting`이 false가 될 때까지 기다린다. 따라서 현재 `start()` 안에서 Zoom을 기다리는 비동기 재시도 루프를 돌리면 다음 문제가 생긴다.

- `running = true`이지만 탭은 없는 상태가 오래 유지된다.
- SpeechTranscriber, WhisperLive, AudioArchive가 입력 없이 먼저 살아 있게 된다.
- 사용자가 정지를 눌러도 `starting`이 끝나기를 기다리므로 대기 해제가 어렵다.
- Zoom이 끝내 나타나지 않을 때 임시 세션과 워커를 모두 별도로 되돌려야 한다.

그러므로 **이번 수정에서는 `waitingForZoom`을 구현하지 않는다.** 일반 모드에서 Zoom 후보가 없으면 전역 탭을 만들지 않고 시작을 즉시 실패시킨다.

권장 시작 흐름은 다음과 같다.

```text
/api/start가 starting/running 자리 선점
  → 관리자 되먹임인지 확인
  → 일반 모드라면 Zoom 후보 존재 여부를 값싼 preflight로 확인
       └─ 없음: zoomAudioProcessUnavailable 즉시 throw
  → 기존 분석 모델·전사기·아카이브 준비
  → SystemAudioTap 생성
       └─ 생성 실패: 준비한 자원 전체 rollback 후 throw
  → 탭 성공 뒤에만 store.beginRecording 및 공유 프로퍼티 commit
  → starting=false, 정상 녹음 상태
```

`preflight`는 “어느 장치·스트림이 최종 경로인가”를 결정하지 않는다. 현재 위험한 전역 폴백을 막기 위해 Zoom 후보가 하나라도 있는지만 검사한다. preflight 뒤 탭 생성 전 프로세스가 사라지는 경쟁은 여전히 가능하므로 탭 생성 실패 rollback도 반드시 있어야 한다.

가능하면 전사기·아카이브·Whisper 워커를 먼저 지역 변수로 준비하고, 탭 시작까지 성공한 뒤 `lectureTranscriber`, `archive`, `whisperLive`, `sentenceBuffer`, `audioSink`, `tap` 공유 프로퍼티에 한 번에 반영하는 **2단계 commit** 구조로 바꾼다. 탭 콜백의 sink는 이 지역 자원을 캡처할 수 있으므로 공유 프로퍼티를 미리 노출할 필요가 없다.

현재 tap-start catch는 `lectureTranscriber`와 `archive`, `audioActivityClock` 일부만 정리한다. `whisperLive`, `sentenceBuffer`, `audioSink`, `store.startedAt`은 남을 수 있다. 전역 폴백 제거와 함께 실패 rollback을 다음처럼 완전하게 만들어야 한다.

- 만들어진 탭과 집합 장치 정지·해제
- `WhisperLive.cancel()` 후 `whisperLive = nil`
- `sentenceBuffer = nil`
- `AudioArchive` 종료 또는 시작 실패 전용 abort 후 `archive = nil`
- `TrackTranscriber.finish()` 후 `lectureTranscriber = nil`
- `audioSink = nil`, `audioActivityClock = nil`
- 강의 경계 Task와 관련 세대 상태 초기화
- `store.beginRecording()`을 이미 호출했다면 timeBase를 증가시키지 않는 시작 취소 메서드로 `startedAt`만 복구

마지막 항목 때문에 실패 rollback에서 일반 `store.endRecording()`을 그대로 쓰면 안 된다. 입력을 한 프레임도 받지 못한 시작 실패가 이어 적기 기준을 2초 증가시킬 수 있기 때문이다.

관리자 모드에서만 시스템 전체 탭을 명시적으로 허용한다. 앱 실행 순서 때문에 실사용 캡처 범위가 몰래 바뀌는 일은 없어야 한다.

#### 나중에 자동 대기가 꼭 필요해질 경우

자동 대기는 위 fail-closed 수정에 덧붙이는 재시도 루프가 아니라 별도의 수명주기 리팩터링이어야 한다. 최소한 다음 상태가 필요하다.

```swift
enum RecordingLifecycle {
  case idle
  case preparing(startRequestID: UUID)
  case waitingForZoom(pendingRequest: PendingRecordingRequest)
  case recording(context: ActiveRecordingContext)
  case stopping(recordingGeneration: UUID)
}
```

이때의 규칙은 다음과 같다.

1. `waitingForZoom`에서는 `running`이 false이며 Store, TrackTranscriber, AudioArchive, WhisperLive를 만들지 않는다.
2. 대기 상태에는 제목·용어·저장 옵션 같은 불변 `PendingRecordingRequest`만 보관한다.
3. Zoom 감시는 취소 가능한 별도 Task가 맡고, 사용자가 정지 또는 취소를 누르면 즉시 종료한다.
4. Zoom 후보가 나타나면 `startRequestID`가 아직 현재 요청인지 재검증한 뒤 동일한 시작 transaction을 새로 실행한다.
5. 오래된 감시 Task는 새 시작 요청이나 이미 진행 중인 녹음을 변경할 수 없다.
6. UI에는 “Zoom 대기 중”을 표시하되 녹음 중으로 표시하지 않는다.

즉 자동 대기를 지원하려면 현재의 `running`/`starting` Bool 조합을 `RecordingLifecycle` 상태 머신으로 대체해야 한다. 이번 두 버그의 1차 수정에는 필요하지 않으므로 별도 변경으로 남긴다.

### 6.3 장치/스트림 고정은 A/B 결과가 허용할 때만 설계한다

`CATapDescription(processes:deviceUID:stream:)`은 현시점의 확정된 운영 설계가 아니라 **진단용 후보**다. 먼저 관리자 A/B 도구에서 프로세스·장치·스트림 조합을 각각 열어 다음을 확인해야 한다.

- 원격 음성이 어느 조합에 존재하는가?
- 로컬 마이크 고유 문구가 어느 조합에 존재하는가?
- 두 신호가 서로 다른 조합으로 분리되는가?
- Zoom의 출력 장치 변경 뒤에도 같은 선택 규칙을 재현할 수 있는가?

A/B 결과가 “원격 음성과 로컬 마이크가 서로 다른 장치 또는 스트림”이라고 증명할 때만 Core Audio의 프로세스 장치 정보(`kAudioProcessPropertyDevices`, 또는 지원 SDK의 `AudioHardwareProcess.devices`)와 `CATapDescription(processes:deviceUID:stream:)`를 사용한 운영 경로를 설계한다.

그때도 macOS 기본 출력 장치를 무조건 쓰면 안 된다. Zoom은 시스템 기본 장치와 다른 스피커를 자체 설정으로 선택할 수 있으므로, 탭 설명과 집합 장치는 A/B에서 검증한 동일 장치를 기준으로 해야 한다.

반대로 같은 스트림에서 두 신호가 함께 관측되면 장치/스트림 resolver 구현을 중단한다. 그 결과에서는 resolver가 마이크 혼입을 해결할 수 없고 불필요한 복잡성만 추가하기 때문이다.

**A/B 진단 결과가 나오기 전까지 `ZoomAudioRouteResolver`의 최종 시그니처나 캡처 경로 모델을 확정하지 않는다.** 로그 포맷만 다음처럼 미리 정할 수 있다.

```text
capture-route generation=... mode=zoomMeetingOutput
processPID=... processObjectID=... bundleID=us.zoom.xos
deviceUID=... deviceName=... streamElement=...
globalFallback=false
```

### 6.4 콜백 heartbeat를 추가한다

`SystemAudioTap.handle`이 유효 버퍼를 공통 sink에 넘기는 바로 그 시점에 heartbeat를 기록한다. 샘플이 모두 0이어도 갱신해야 한다.

```swift
final class AudioCaptureHeartbeat: @unchecked Sendable {
  private let lock = NSLock()
  private let monotonicClock = ContinuousClock()
  private var lastAudioBufferArrival: ContinuousClock.Instant?

  /// 샘플의 음량과 관계없이 호출한다. 이 시각은 콘텐츠가 아니라
  /// Core Audio 전달 경로가 살아 있는지를 판단하기 위한 값이다.
  func recordAudioBufferArrival() {
    lock.withLock {
      lastAudioBufferArrival = monotonicClock.now
    }
  }
}
```

실제 구현에서는 캡처 세대와 마지막 콜백 시각을 한 스냅샷으로 반환해 stop/start 경쟁을 막는다. 이름이 짧은 `lastAt`, `gen` 대신 `lastAudioBufferArrival`, `captureRouteGeneration`처럼 역할이 드러나는 이름을 사용한다.

권장 판정 주기는 다음과 같다.

- 건강 상태 평가: 5초마다
- 마지막 콜백이 3초 이상 전이면 일단 `callbackStalled` 후보
- 2회 연속 확인되거나 즉시 HAL 오류가 확인되면 사용자 경고
- 경고 전에 현재 프로세스·장치·스트림을 다시 조회하여 `targetProcessLost`와 `routeChanged`를 구분

정확한 시간값은 실제 콜백 간격 로그를 먼저 모아 조정해야 하지만, 오디오 콜백은 정상 상태에서 초당 여러 번 도착하므로 수 초 단위의 heartbeat 기준과 30초 콘텐츠 무음 기준은 충분히 분리할 수 있다.

### 6.5 기존 30초 경고와 180초 강의 경계를 분리한다

현재 `startSilenceWatchdog` 한 곳에서 두 정책을 처리하지만, 다음 두 평가기로 논리적으로 분리하는 편이 안전하다.

```text
evaluateCaptureHealth()
  └─ heartbeat + route validity → 장애 UI 여부

evaluateLectureBoundary()
  └─ capture health가 quiet인가?
       └─ 기존 silencePeriod.duration >= 180인가?
            └─ 기존 flush → Whisper idle → 같은 무음 재검증 → 경계 기록
```

180초 임계값과 `lastNonSilentAt` 계산은 바꾸지 않는다. 단지 `callbackStalled`, `targetProcessLost`, `routeChanged`, `tapInvalid` 상태에서는 강의 종료 처리를 시작하지 않는다. 콜백이 살아 있고 0 PCM이 계속 도착하는 정상 `quiet`만 강의 무음으로 인정한다.

이 보강은 `volatile`을 더 빨리 지우지 않는다. 오히려 캡처 장애를 무음으로 오인해 오래된 작업이 문장을 정리하는 위험을 줄인다. 기존의 Whisper 대기 후 `hasMaintainedSilence` 재검증과 녹음 세대 검사는 그대로 남긴다.

### 6.6 `isPlaying` 계열 API와 주석을 바로잡는다

기존 함수가 다른 곳에서 필요하다면 삭제하지 않고 실제 의미에 맞게 이름과 주석을 바꾼다.

```swift
/// 프로세스가 출력 I/O를 실행하며 활성 출력 스트림을 가지고 있는지 확인한다.
/// 샘플이 실제 음성인지, 전부 0인지는 이 값만으로 판단할 수 없다.
static func hasActiveOutputIO(_ audioProcess: AudioProcessInfo) -> Bool
```

- `isAnythingPlaying()` → `hasAnyProcessWithActiveOutputIO()`
- `playingBundleIDs()` → `activeOutputIOBundleIDs()`

그러나 이름을 고친 뒤에도 이 값만으로 빨간 무음 팝업을 만들면 안 된다. 경로 진단의 보조 정보로만 사용한다.

### 6.7 경로 변경 시 안전하게 탭을 재생성한다

출력 장치나 Zoom 프로세스가 바뀌면 다음 순서를 지킨다.

1. 캡처 경로 세대를 증가시킨다.
2. 이전 탭의 콜백이 더 이상 공통 sink를 갱신하지 못하게 세대 검사를 건다.
3. 새 Zoom process/device/stream 경로를 계산한다.
4. 새 탭을 먼저 준비하고 성공을 확인한다.
5. 안전한 교체가 가능한 경우 새 탭으로 전환한 뒤 이전 탭을 정리한다.
6. 실패하면 전역 폴백하지 않고 명시적인 `tapInvalid` 상태를 유지한다.

SpeechTranscriber와 Whisper 워커를 불필요하게 합치거나 서로 기다리게 하지 않는다. 탭 교체는 **동일한 원본 PCM sink의 공급자만 바꾸는 작업**이어야 한다.

## 7. 구현 전에 반드시 해야 할 격리 진단

기존 관리자 WAV 되먹임은 전사·Whisper·180초 경계를 검증하는 데 적합하지만 `SystemAudioTap`을 우회한다. 따라서 이번 두 캡처 문제를 재현하거나 해결을 검증할 수 없다.

별도의 관리자 전용 “실제 탭 진단”을 추가해 scratch 저장소와 새 포트에서만 실행해야 한다. 실사용 앱은 재시작하거나 정지하지 않는다.

### 7.1 프로세스·장치·스트림 A/B 행렬

각 후보에 대해 원본 오디오 가공 없이 다음 값만 측정한다.

- bundle ID, PID, AudioObjectID
- 현재 사용 중인 출력 device UID와 이름
- output stream element
- 초당 콜백 수와 최장 콜백 간격
- peak/RMS와 0이 아닌 프레임 비율
- 고유 테스트 문구가 어느 경로의 전사에 나타났는지

시험 단계는 다음과 같다.

1. 원격 음성 재생, 로컬 마이크 끔
2. 원격 음성 정지, 로컬 마이크 켜고 고유 문구 발화
3. 원격 음성과 로컬 마이크를 동시에 사용
4. 마이크 끔으로 복귀
5. Zoom 출력 장치 변경
6. Zoom을 앱보다 먼저 실행 / 앱을 Zoom보다 먼저 실행

현재 `us.zoom.xos` 전체 혼합, `us.zoom.xos`의 장치별·스트림별 탭, 각 Zoom 헬퍼 개별 탭을 비교한다. 이 결과로 원격 음성은 남고 로컬 문구가 사라지는 가장 좁은 경로를 선택한다.

시험에는 헤드폰을 사용해 스피커 소리가 실제 마이크로 다시 들어가는 물리적 acoustic echo와 소프트웨어 경로 혼입을 구분한다.

A/B 결과에 따른 다음 단계는 미리 다음처럼 고정한다. 이렇게 해야 진단 뒤에 유리한 결과만 골라 이미 생각해 둔 resolver 설계를 밀어붙이는 일을 막을 수 있다.

| A/B 결과 | 판단 | 다음 구현 |
|---|---|---|
| Zoom을 못 찾아 전역 폴백한 경우에만 로컬 음성 혼입 | 캡처 범위 확대가 원인 | 전역 폴백 제거로 종료; 장치/스트림 resolver를 만들지 않음 |
| 특정 Zoom 헬퍼에만 로컬 음성이 있고 회의 음성 프로세스와 분리됨 | 프로세스 단위 분리 가능 | 검증된 회의 프로세스만 선택하는 최소 경로 구현 |
| 같은 프로세스지만 서로 다른 장치·스트림에 존재 | 장치/스트림 단위 분리 가능 | 그때 `processes:deviceUID:stream:` 기반 경로 모델 설계 |
| 같은 프로세스·장치·스트림에서 함께 관측 | Core Audio 탭으로 분리 불가능 | resolver 설계 중단; 엄격 요구라면 Meeting SDK 검토 |

진단 코드는 운영 경로와 분리된 관리자 전용 probe여야 한다. probe에서 사용한 클래스나 메서드 시그니처를 검증 없이 운영 코드로 승격하지 않는다.

### 7.2 무음/중단 상태 행렬

다음 상태를 각각 독립적으로 검증한다.

- 원격 발표자 60~120초 침묵: `quiet`, 빨간 팝업 없음
- 180초 정상 침묵: 기존 강의 종료 경계 정확히 한 번
- 180초 전에 발화 재개: 경계 없음
- 탭 콜백을 시험 훅으로 중단: `callbackStalled`, 강의 경계 없음
- Zoom 프로세스 종료: `targetProcessLost`, 전역 캡처 없음
- 출력 장치 변경: `routeChanged` 또는 성공적인 자동 재연결
- 재연결 뒤 발화: 실시간 자막 즉시 재개, Whisper 독립 재전사 지속

## 8. 장치·스트림으로도 로컬 음성을 분리할 수 없는 경우

A/B 결과 원격 음성과 로컬 마이크 되울림이 이미 **같은 Zoom 프로세스의 같은 장치·같은 출력 스트림**에 섞여 있다면 Core Audio 탭 뒤에서는 완전 분리가 불가능하다. 이미 합쳐진 PCM에는 화자 ID가 없기 때문이다.

이 경우 선택지는 요구 수준에 따라 달라진다.

### 엄격한 요구: 로컬 음성이 WAV에도 절대 남으면 안 됨

Zoom Meeting SDK의 raw audio 기능처럼 참가자별 one-way audio와 `userID`를 제공하는 소스가 필요하다. 자기 자신 ID를 제외한 원격 참가자 데이터만 합쳐 전사와 저장으로 보낸다.

다만 이는 현재 사용자가 별도 Zoom 데스크톱 앱으로 회의에 참여하고 옆에서 캡처하는 구조의 작은 수정이 아니다. 애플리케이션이 Meeting SDK를 통해 회의 참가를 담당해야 할 수 있고 raw data 라이선스 조건도 확인해야 한다. 따라서 장치·스트림 분리가 실패했을 때만 검토할 제품 아키텍처 변경이다.

### 완화된 요구: 최종 텍스트에서만 자기 발화를 제외

사용자가 명시적으로 동의한 경우에만 로컬 마이크를 메모리상의 참조 트랙으로 짧게 전사하고, 시간과 텍스트가 강하게 일치하는 구간을 “본인 발화”로 표시해 최종 문장에서 제외하는 방법이 있다.

이 방식은 동시 발화에서 틀릴 수 있고 원본 WAV에는 로컬 음성이 남으므로 엄격한 개인정보 요구를 충족하지 않는다. 기본 해결책으로 권장하지 않는다.

### 사용하지 않을 방법

- 노이즈 억제, 정규화, VAD 조정으로 로컬 음성을 제거
- 믹스된 파형에 대한 적응형 마이크 상쇄
- 단순 볼륨 임계값으로 로컬/원격 구분

이들은 출처 식별을 보장하지 못하며, 이 프로젝트에서 이미 확인한 “원본 오디오가 전사 정확도가 가장 좋다”는 결과를 훼손할 수 있다.

## 9. 로그 신뢰성 문제

2026-09-09 로그에는 실사용 프로세스와 격리 관리자 프로세스의 기록이 같은 파일에 섞였고, 한 줄 안에 두 타임스탬프가 이어 붙은 사례도 있다. 현재 로거의 직렬화가 프로세스 내부에서만 동작하고 여러 프로세스가 같은 파일 오프셋으로 쓰기 때문이다.

예를 들어 10:23 실사용 Whisper 로그 한가운데 11:19 관리자 시험 세션 생성 로그가 붙어 있다. 11:23의 180초 경계 기록도 관리자 scratch 시험 기록이므로 10시 실사용 세션의 경계로 해석하면 안 된다.

구현 전에 다음 중 하나로 로그를 분리한다.

- 권장: `zoomcaption-<date>-pid-<pid>-<mode>.log`처럼 프로세스별 파일 사용
- 대안: 원자적 append와 프로세스 간 파일 잠금을 함께 적용

모든 캡처 로그에 `processID`, `admin/live mode`, `recordingGeneration`, `captureRouteGeneration`, `sessionDirectory`를 넣으면 다음 진단에서 세션 혼동을 막을 수 있다.

## 10. 권장 구현 순서

### P0 — 관측 가능성과 fail-closed 시작

1. 프로세스별 로그 파일로 관리자/실사용 기록을 분리한다.
2. 현재 캡처 시작 때 process/device/stream/global-fallback 여부를 구조화해 기록한다.
3. `AudioCaptureScope`로 관리자 시스템 캡처와 실사용 Zoom 캡처를 구분한다.
4. 일반 모드의 전역 폴백을 제거하고, Zoom 후보가 없으면 동기적으로 시작을 실패시킨다.
5. tap-start 실패 rollback에서 WhisperLive, sentenceBuffer, audioSink, store.startedAt까지 완전히 정리한다.

이 단계는 음성 파형을 바꾸지 않으면서 가장 위험한 범위 확대를 즉시 막는다.

### P1 — 무음 오탐 수정

1. `isPlaying` 계열을 실제 의미인 `hasActiveOutputIO`로 이름과 주석을 고친다.
2. `AudioCaptureHeartbeat`를 추가한다.
3. 캡처 건강 상태 열거형과 평가기를 추가한다.
4. `quiet`에는 빨간 팝업을 띄우지 않는다.
5. 180초 경계는 `quiet`에서만 허용하되 기존 경계 내부 로직은 그대로 둔다.

### P2 — 마이크 혼입 위치 A/B 진단

1. 운영 코드와 분리된 관리자 실제 탭 probe를 만든다.
2. Zoom 프로세스별 캡처를 먼저 비교한다.
3. 필요한 경우에만 장치별·스트림별 캡처를 비교한다.
4. 로컬 고유 문구와 원격 고유 문구가 분리되는 가장 좁은 지점을 기록한다.
5. 이 단계가 끝날 때까지 `ZoomAudioRouteResolver`의 최종 타입과 시그니처를 만들지 않는다.

### P3 — A/B 결과에 맞는 최소 운영 경로 구현

1. 전역 폴백 문제라면 폴백 제거 외 경로 추상화를 추가하지 않는다.
2. 프로세스 단위로 분리되면 검증된 프로세스 선택만 구현한다.
3. 장치·스트림 단위로 분리될 때만 `processes:deviceUID:stream:` 경로와 변경 감시를 설계한다.
4. 선택된 경우에만 경로 세대 기반 안전한 재연결을 구현한다.

### P4 — 동일 스트림 혼합일 때만 제품 결정

1. WAV까지 로컬 음성 배제가 필수인지 결정한다.
2. 필수라면 Zoom Meeting SDK 참가자별 raw audio 구조를 별도 설계한다.
3. 텍스트 제외만 필요하다면 명시적 동의가 있는 로컬 참조 트랙 방식을 제한적으로 검토한다.

## 11. 완료 기준

수정은 다음 조건을 모두 만족해야 완료로 본다.

- 정상적인 30~179초 Zoom 침묵에는 권한 오류 빨간 팝업이 뜨지 않는다.
- 콜백 중단, 대상 소실, 장치 변경을 서로 다른 상태와 메시지로 구분한다.
- 콜백이 끊긴 동안에는 180초 강의 경계를 기록하지 않는다.
- 콜백이 살아 있는 180초 침묵에서는 기존 강의 종료 표시가 정확히 한 번 기록된다.
- 침묵 도중 음성이 돌아오면 기존 재검증이 오래된 `volatile`을 지우지 않는다.
- 일반 모드에서 Zoom 대상을 못 찾았을 때 시스템 전체 오디오를 캡처하지 않는다.
- Zoom 후보가 없으면 `/api/start`가 대기 상태에 머물지 않고 구체적인 오류로 끝나며 `running`과 `starting`이 모두 복구된다.
- 탭 생성 실패 뒤 WhisperLive, sentenceBuffer, audioSink, store.startedAt 같은 부분 초기화 상태가 남지 않는다.
- 로컬 마이크만 켜고 말한 고유 문구가 실시간 자막, Whisper 결과, 저장 WAV 어디에도 나타나지 않는다.
- 원격 음성은 로컬 마이크 on/off와 무관하게 동일하게 캡처된다.
- SpeechTranscriber와 Whisper는 서로 독립적으로 계속 작동한다.
- 오디오 전처리·정규화·필터링을 추가하지 않는다.
- 관리자 시험 로그와 실사용 로그가 섞이거나 한 줄에서 손상되지 않는다.

## 12. 참고한 공식 문서

- Apple, [AudioHardwareProcess.isRunningOutput](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/isrunningoutput)
- Apple, [AudioHardwareProcess](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess)
- Apple, [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- Apple, [CATapDescription.init(processes:deviceUID:stream:)](https://developer.apple.com/documentation/coreaudio/catapdescription/init%28processes%3Adeviceuid%3Astream%3A%29)
- Apple, [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- Zoom, [ZoomSDKRawDataController](https://marketplacefront.zoom.us/sdk/meeting/macos/interface_zoom_s_d_k_raw_data_controller.html)
- Zoom, [ZoomSDKAudioRawDataDelegate](https://marketplacefront.zoom.us/sdk/meeting/macos/protocol_zoom_s_d_k_audio_raw_data_delegate_01-p.html)

## 13. 이번 보고서의 판단 범위

이 보고서는 현재 로그와 소스로 확정 가능한 원인과, 추가 A/B 시험이 필요한 가설을 구분했다.

- 무음 팝업의 직접 원인은 확정적이다: `isRunningOutput`을 실제 audible output으로 해석한 의미 오류다.
- 현재 세션의 PCM이 실제 0이었다는 것도 로그로 확인된다.
- 마이크 음성이 앱의 직접 마이크 입력에서 온 것이 아니라 Zoom/전역 출력 탭을 통해 들어온다는 판단은 소스 구조상 강하다.
- 어느 Zoom 프로세스·장치·스트림에서 마이크 신호가 섞이는지는 현재 로그만으로 확정할 수 없으므로 관리자 실제 탭 A/B가 필요하다.
- 현재 시작 수명주기에는 백그라운드 `waitingForZoom`이 맞지 않으므로, 1차 수정은 fail-closed 즉시 실패로 한정한다.
- 장치·스트림 단위 resolver의 형태는 A/B 결과가 분리 가능성을 증명한 뒤에만 확정한다.
- 같은 출력 스트림에 이미 섞였는지 확인하기 전에는 파형 제거 또는 SDK 전환을 성급하게 구현하지 않는다.

## 14. 반영 상태와 남은 확인

현재 코드에는 P0과 P1, 그리고 P2의 관리자 진단 도구까지 반영했다.

- 일반 녹음은 Zoom 후보가 없으면 전역 캡처로 넓히지 않고 즉시 실패한다.
- 탭 성공 뒤에만 Store 녹음 시각을 열며, 실패하면 이미 만든 전사기·Whisper·Archive·sink를 모두 정리한다.
- 모든 유효 버퍼로 갱신되는 monotonic heartbeat를 콘텐츠 활동 시계와 분리했다.
- 0 PCM이 계속 도착하는 정상 침묵은 빨간 오류가 아니며, 콜백 중단과 대상 소실은 각각 두 번 연속 확인한 뒤에만 오류로 확정한다.
- 실제 탭의 전달 경로가 불건전할 때는 180초 강의 종료 경계를 만들지 않는다. 관리자 파일 되먹임은 탭이 없는 것이 정상이라 기존 경계 시험을 그대로 허용한다.
- 실사용과 관리자 로그를 역할·PID별 파일로 분리하고, 오늘 실행 중일 수 있는 다른 프로세스의 로그도 prune에서 보호한다.
- 관리자 UI에서 `us.zoom.*` 프로세스 전체와 장치·스트림 조합을 선택해 callback 수, 최근 간격, peak, RMS, non-silent 비율을 비교할 수 있다.

격리 시험에서 `us.zoom.xos` 프로세스 전체와 내장 스피커 stream 0 모두 원격 강의 오디오 콜백을 받는 것은 확인했다. 그러나 현재 실사용 녹음을 방해하지 않기 위해 **로컬 마이크 on/off 고유 문구 A/B는 아직 수행하지 않았다.** 따라서 P3 운영 resolver는 의도적으로 구현하지 않았으며 마이크 혼입도 해결 완료로 판정하지 않는다. 이 A/B가 어느 계층에서 원격 음성과 로컬 마이크가 갈라지는지 증명한 뒤 표 7.2의 해당 분기만 구현해야 한다.

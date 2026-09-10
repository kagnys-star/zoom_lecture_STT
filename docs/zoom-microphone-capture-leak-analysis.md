# Zoom 마이크 음성이 강의 캡처에 유입되는 문제 진단 보고서

작성일: 2026-09-09
대상 브랜치: `feature/whisper-vad-paragraphs`
대상 버전: `64046db` 이후 현재 작업 트리

## 1. 결론

이 문제는 `transcripter`나 Whisper가 마이크를 별도로 열어서 생긴 문제가 아니다. 현재 앱에서 실시간 전사와 Whisper용 WAV에 들어가는 실제 오디오 입력은 `SystemAudioTap` 하나뿐이다. 따라서 Zoom 마이크를 켰을 때 내 목소리가 자막이나 저장 WAV에 나타난다면, 그 음성은 **이미 Core Audio의 Zoom 출력 탭에 포함된 상태로 앱에 전달된 것**이다.

현재 구현은 Zoom으로 분류한 프로세스들의 모든 출력 스트림을 `stereoMixdownOfProcesses`로 먼저 하나의 스테레오 신호로 합친다. 그 뒤에는 출처 정보가 전혀 남지 않는다. 로컬 마이크에서 유래한 음성이 Zoom의 어떤 출력 경로에 나타나면, 앱은 그것을 원격 참가자 음성과 구별할 수 없고 그대로 다음 두 경로에 동시에 보낸다.

```text
Zoom 프로세스 출력 전체
        │
        ▼
CATapDescription(stereoMixdownOfProcesses: ...)
        │  여기서 출처가 사라진 하나의 PCM 신호가 됨
        ├────────► SpeechTranscriber ─► 실시간 자막
        └────────► AudioArchive ──────► 약 1분 30초 뒤 Whisper 재전사
```

즉, 1차 원인은 **캡처 범위가 “원격 참가자 음성”이 아니라 “Zoom 프로세스가 내보내는 출력 전체”인 것**, 2차 원인은 **Zoom 대상을 찾지 못하면 조용히 시스템 전체 캡처로 바뀌는 폴백**, 3차 원인은 **실제로 어떤 프로세스·장치·스트림을 선택했는지 기록하지 않는 관측성 부족**이다.

가장 먼저 할 수정은 전역 폴백을 없애고, Zoom 회의 출력 프로세스와 현재 출력 장치의 특정 스트림으로 탭을 제한하는 것이다. 다만 로컬 마이크 음성과 원격 음성이 Zoom 내부에서 이미 같은 출력 스트림에 합쳐져 있다면 `CATapDescription`만으로 다시 분리할 수 없다. 이 경우에는 Zoom이 제공하는 분리된 회의 오디오를 사용하거나, 별도 마이크 참조 신호로 로컬 발화를 제거하는 2단계 설계가 필요하다.

## 2. 확인 범위와 증거 수준

### 코드와 실행 상태로 확정한 사실

1. 앱의 실제 오디오 입력은 `SystemAudioTap` 하나다.
   - [`AudioTap.swift`](../Sources/ZoomCaption/Audio/AudioTap.swift)의 현재 구현에는 `AVAudioEngine.inputNode`나 별도 마이크 입력 장치 오픈이 없다.
   - `Info.plist`에는 과거 기능 설명으로 보이는 `NSMicrophoneUsageDescription`이 남아 있지만, 사용 설명 키가 있다는 것만으로 마이크 오디오가 자동 캡처되지는 않는다.

2. Zoom 대상은 번들 ID만으로 한 번 선택한다.
   - `SystemAudioTap.zoomBundleIDs`에는 `us.zoom.xos`, `us.zoom.ZoomClips`, `us.zoom.ZoomLauncher`, `us.zoom.ZoomAudioDaemon`이 들어 있다.
   - 캡처 시작 순간의 `AudioObjectID` 배열을 만든 뒤 `CATapDescription(stereoMixdownOfProcesses:)`에 넘긴다.
   - 탭을 만든 뒤 Zoom 프로세스가 교체되거나 새 helper가 등장해도 대상 목록을 갱신하지 않는다.

3. 선택한 Zoom 프로세스의 출력은 탭에서 스테레오로 합쳐진다.
   - Apple은 `CATapDescription`의 입력이 지정한 프로세스 출력 오디오의 혼합이라고 설명한다.
   - `stereoMixdownOfProcesses`는 주어진 프로세스들의 오디오 스트림을 스테레오로 모두 섞는다.
   - 따라서 믹스다운 이후에는 “원격 참가자”, “로컬 마이크에서 유래한 Zoom 출력”, “효과음” 같은 출처를 PCM만 보고 직접 식별할 수 없다.

4. 탭 버퍼는 필터 없이 두 전사 경로에 함께 들어간다.
   - `ZoomCaptionApp.start`의 `audioSink`는 같은 `audioBuffer`를 `lecture.feed(...)`와 `recordingAudioArchive.write(...)`에 전달한다.
   - 그래서 이 문제는 실시간 자막에만 나타나는 문제가 아니다. 소스 단계에서 섞였다면 Whisper도 지연 재전사 시 같은 음성을 다시 처리한다.

5. 관리자 모드는 의도적으로 시스템 전체 출력을 캡처한다.
   - `--admin` 또는 `ZOOMCAPTION_ADMIN=1`이면 `zoomOnly`가 `false`가 되어 전역 탭이 만들어진다.
   - 관리자 WAV 되먹임은 저장 파일을 `audioSink`에 직접 넣으므로 마이크 유입 문제의 소스 진단에는 사용할 수 없다. 이 문제는 관리자 모드의 **실시간 시스템 캡처 시험**으로 재현해야 한다.

6. 일반 모드에서도 Zoom 대상을 못 찾으면 전역 탭으로 바뀐다.
   - 현재 조건은 `(zoomOnly && !targets.isEmpty) ? Zoom 탭 : 전역 탭`이다.
   - Zoom이 늦게 뜨거나, 번들 ID가 바뀌거나, Core Audio 프로세스 객체가 아직 등록되지 않은 짧은 순간에 시작하면 모든 앱의 출력이 캡처된다.
   - 전역 탭도 물리 마이크 입력을 직접 읽는 것은 아니지만, 어느 앱이 마이크를 출력으로 재생하거나 모니터링하면 그 신호까지 캡처 범위에 들어간다.

7. 현재 실행은 관리자 모드가 아니다.
   - `/api/admin`의 `enabled`는 `false`였다.
   - 현재 Core Audio 프로세스 목록에는 `us.zoom.xos`와 `us.zoom.caphost`가 함께 보였다.
   - Zoom 메인 프로세스는 08:48, ZoomCaption은 08:52, 현재 녹음은 09:00에 시작했다. 따라서 이번 실행에서 시작 시점 전역 폴백이 작동했을 가능성은 낮지만, 시작 시 선택한 대상을 로그로 남기지 않아 완전히 배제할 수는 없다.

### 사용자 재현 결과를 바탕으로 한 강한 추론

Zoom 마이크를 켤 때만 로컬 음성이 캡처된다면, Zoom의 마이크 활성화가 Zoom 프로세스의 출력 토폴로지를 바꾸거나 로컬 신호를 어떤 출력 스트림에 포함시키는 것이다. 가능한 형태는 다음과 같다.

- Zoom의 마이크 테스트/재생 경로
- Zoom의 로컬 모니터 또는 음향 처리 경로
- 같은 회의를 다른 장치나 참가자가 되돌려 보내는 실제 에코
- Core Audio가 Zoom 프로세스 출력으로 분류하는 내부 오디오 경로

Zoom은 비공개 구현이므로 코드만 보고 이 네 가지 중 어느 것인지 확정할 수 없다. 그러나 어느 경우든 현재 앱이 로컬 음성을 받아들이는 직접 원인은 동일하다. **Zoom 프로세스 출력 전체를 합친 뒤 아무 출처 판정 없이 전사기에 넣기 때문**이다.

### 아직 확정하지 못한 사항

- 로컬 음성이 `us.zoom.xos`와 `us.zoom.caphost` 중 어느 프로세스 출력에 존재하는지
- 로컬 음성과 원격 음성이 서로 다른 출력 장치 스트림에 있는지, 이미 같은 스트림에 합쳐졌는지
- 문제가 일반 회의 중 단순 음소거 해제에서도 발생하는지, Zoom의 “마이크 테스트”나 상대방 에코가 있을 때만 발생하는지
- 문제 발생 세션이 시작 시 Zoom 전용 탭이었는지 전역 폴백이었는지

이 네 항목은 수정 전에 짧은 A/B 캡처로 확인해야 한다. 이를 확인하지 않고 번들 ID만 임의로 추가하거나 제거하면 원격 강의 소리까지 잃을 수 있다.

## 3. 현재 코드에서 문제가 만들어지는 지점

### 3.1 프로세스 단위 선택이 의미하는 것

현재 코드는 다음과 같은 의미다.

```swift
let targets = CoreAudioInfo.processes()
  .filter { SystemAudioTap.zoomBundleIDs.contains($0.bundleID) }
  .map(\.objectID)

let description = CATapDescription(stereoMixdownOfProcesses: targets)
```

이 코드는 “Zoom에서 들리는 교수 목소리만”을 요청하지 않는다. Core Audio에는 참가자 역할 개념이 없으므로 “이 프로세스들이 출력하는 오디오를 전부 섞어 달라”고 요청한다. Apple의 공식 설명도 process tap을 프로세스 또는 프로세스 그룹의 **outgoing audio**를 캡처하는 장치로 정의한다.

따라서 Zoom이 로컬 마이크에서 유래한 오디오를 자신의 출력으로 노출하는 순간, 그 신호도 `targets`의 정상 출력으로 취급된다.

### 3.2 믹스다운 이후에는 늦게 고칠 수 없다

`stereoMixdownOfProcesses`가 반환한 버퍼에는 원래 프로세스 ID, 스트림 번호, 참가자 ID가 없다. `AudioResampler`, `SpeechTranscriber`, `AudioArchive`, Whisper 어느 단계도 그 신호의 출처를 복원할 수 없다.

따라서 다음 방식은 근본 해결이 아니다.

- 음량이 큰 구간 삭제: 교수 음성도 함께 삭제될 수 있다.
- VAD로 음성만 걸러내기: 로컬 음성도 정상적인 음성이므로 그대로 통과한다.
- Whisper 프롬프트로 “내 목소리를 무시” 지시: Whisper에는 화자 신원을 판별할 근거가 없다.
- 왼쪽/오른쪽 채널 중 하나만 사용: stereo mixdown은 모노 소스를 좌우에 복제할 수 있어 신원 분리에 쓸 수 없다.
- `muteBehavior` 변경: 이 값은 탭 대상 소리를 스피커로 계속 보낼지 정하는 재생 정책이지, 마이크 제외 필터가 아니다.

### 3.3 전역 폴백이 증상을 확대한다

현재 일반 모드의 `targets.isEmpty`는 오류가 아니라 전역 캡처 요청으로 해석된다. 사용자 화면과 로그에는 이 전환이 표시되지 않는다. 이 상태에서는 Zoom뿐 아니라 브라우저, 음악 앱, 알림음 등 모든 프로세스 출력이 강의 음성으로 들어간다.

이 폴백은 “Zoom 전에 앱을 켜 둔다”는 편의를 위해 들어갔지만, 캡처 정확성과 개인정보 측면에서 실패 시 범위를 넓히는 동작이다. 정상 모드는 Zoom 대상을 못 찾았을 때 **아무것도 캡처하지 않고 대기**해야 한다.

### 3.4 관리자 모드와 일반 모드의 차이

| 실행 조건 | 실제 소스 | 마이크 유래 출력이 섞일 가능성 |
|---|---|---|
| 일반 모드, Zoom 대상 발견 | 선택된 Zoom 프로세스 출력 전체 | Zoom이 그 신호를 출력으로 노출하면 있음 |
| 일반 모드, Zoom 대상 미발견 | 시스템 전체 출력 | 더 높음. 다른 모니터링 앱의 출력도 포함 |
| 관리자 모드 실시간 캡처 | 시스템 전체 출력 | 진단에는 유용하지만 제품 동작으로는 넓음 |
| 관리자 WAV 되먹임 | 선택한 WAV 파일 | 실제 Zoom/마이크 라우팅을 재현하지 못함 |

## 4. 권장 해결 순서

### 4.1 1단계 — 캡처 모드를 명시하고 전역 폴백 제거

현재 `zoomOnly: Bool`은 `false`가 “관리자 전역 캡처”인지 “Zoom 탐색 실패 폴백”인지 표현하지 못한다. 의미가 분명한 타입으로 바꿔야 한다.

```swift
enum AudioCaptureScope {
  /// 실사용 모드. Zoom 회의 출력만 허용하며 대상을 못 찾으면 캡처하지 않는다.
  case zoomMeetingOutput

  /// 관리자 시험에서만 사용하는 시스템 전체 출력 캡처다.
  case administratorSystemOutput
}
```

실사용 모드에서 Zoom 오디오 프로세스를 못 찾으면 `stereoGlobalTapButExcludeProcesses: []`를 만들지 않는다. 대신 다음 상태를 사용자에게 보인다.

```text
Zoom 회의 오디오를 기다리는 중입니다.
Zoom 회의에 들어간 뒤 자동으로 캡처를 시작합니다.
```

프로세스 목록 변경은 `kAudioHardwarePropertyProcessObjectList` 리스너로 감시한다. Zoom 대상이 생기면 탭을 만들고, 대상 `AudioObjectID`가 사라지거나 출력 장치가 바뀌면 기존 탭과 aggregate device를 안전한 순서로 닫고 새 경로로 다시 만든다.

이 단계는 마이크와 원격 음성이 같은 Zoom 출력에 이미 합쳐진 경우까지 해결하지는 못하지만, 전역 캡처라는 별도의 유입 경로를 확실히 제거한다.

### 4.2 2단계 — 실제 캡처 경로를 기록

탭 생성 결과를 다음 불변 스냅샷으로 보관하고 로그와 `/api/diag`에 노출한다.

```swift
struct AudioCaptureRouteSnapshot: Sendable {
  let captureScope: AudioCaptureScope
  let selectedProcesses: [AudioProcessInfo]
  let outputDeviceUID: String
  let outputDeviceName: String
  let outputStreamIndex: UInt
  let sourceSampleRate: Double
  let sourceChannelCount: Int
  let startedAt: Date
}
```

로그에는 최소한 다음이 있어야 한다.

```text
캡처 경로: zoomMeetingOutput
대상: pid=1211 bundle=us.zoom.xos objectID=...
출력: MacBook Pro 스피커 uid=... stream=0
포맷: 48000 Hz, 2ch
```

대상을 못 찾았을 때도 `전역 폴백`이 아니라 `Zoom 대상 없음 — 대기`라고 남긴다. 이렇게 해야 재현 한 번으로 실제 원인을 판별할 수 있다.

### 4.3 3단계 — 출력 장치와 스트림까지 탭 범위 축소

현재 생성자는 선택한 프로세스들의 모든 출력 스트림을 스테레오로 합친다. Apple은 특정 출력 장치 UID와 스트림 인덱스를 함께 지정하는 생성자도 제공한다.

```swift
let zoomOutputDescription = CATapDescription(
  processes: meetingAudioProcessObjectIDs,
  deviceUID: selectedOutputDeviceUID,
  stream: selectedOutputStreamIndex
)
```

이 방식은 “선택한 Zoom 프로세스가 선택한 물리 출력 스트림으로 보내는 오디오”로 범위를 줄인다. 현재 사용 중인 기본 출력 장치를 aggregate device의 anchor로만 쓰지 말고, tap description에도 같은 UID와 stream을 명시한다.

초기 대상은 실제 회의 오디오를 담당한다고 이미 주석에 명시된 `us.zoom.xos` 하나로 제한하는 편이 안전하다. `ZoomLauncher`, `ZoomClips`, `ZoomAudioDaemon`, 현재 실행에서 보인 `us.zoom.caphost`를 이름만 보고 함께 넣어서는 안 된다. 관리자 진단에서 각 프로세스를 별도 탭으로 관찰해 원격 음성을 내는 프로세스만 허용해야 한다.

이 단계의 결과는 두 가지로 갈린다.

- 로컬 마이크 유래 신호가 다른 프로세스나 다른 장치 스트림에 있었다면: 여기서 해결된다.
- 로컬 음성과 원격 음성이 `us.zoom.xos`의 같은 장치 스트림에 이미 섞였다면: 다음 단계가 필요하다.

### 4.4 4단계 — 관리자 모드에 소스 식별 A/B 시험 추가

관리자 모드에서 각 Zoom 프로세스를 동시에 합치지 말고 개별 탭으로 10초씩 관찰한다. 사용자가 다음 네 구간을 명시적으로 전환한다.

1. 원격 음성 없음 + Zoom 마이크 끔 + 말하지 않음
2. 원격 음성 없음 + Zoom 마이크 켬 + 로컬 사용자가 말함
3. 원격 참가자가 말함 + Zoom 마이크 끔
4. 원격 참가자가 말함 + Zoom 마이크 켬

각 프로세스·스트림별로 다음 값만 저장한다.

- PID, bundle ID, `AudioObjectID`
- 출력 장치 UID와 stream index
- 100ms 단위 peak/RMS
- 실제 PCM을 저장할 경우 사용자가 누른 진단 녹음 버튼의 명시적 동의와 짧은 보관 시간

결과 판정은 다음과 같다.

| 관찰 결과 | 수정 방향 |
|---|---|
| 로컬 음성과 원격 음성이 서로 다른 프로세스 | 원격 프로세스만 allowlist |
| 같은 프로세스지만 다른 device stream | `processes:deviceUID:stream:`으로 원격 stream만 선택 |
| 같은 프로세스·같은 stream | Core Audio 탭만으로는 분리 불가, 4.5 적용 |
| 마이크 테스트 때만 로컬 음성이 출력됨 | 테스트 재생은 정상 출력으로 분류하고 UI에 예외 안내 |
| 상대방 장치가 내 음성을 되돌려 보냄 | 이미 원격 수신 음성이므로 로컬 프로세스 필터로 제거 불가 |

### 4.5 5단계 — 같은 스트림에 섞인 경우의 해결

같은 PCM 스트림에 합쳐진 뒤에는 프로세스 ID 필터로 나눌 수 없다. 선택지는 다음 우선순위다.

### 선택 A: 분리된 회의 오디오 소스 사용

Zoom이 참가자 또는 수신 방향을 구분한 원시 오디오를 공식 SDK/API로 제공하고 현재 배포 조건에서 사용할 수 있다면 가장 정확하다. 이 경우 로컬 송신 마이크 프레임은 버리고 원격 수신 프레임만 `audioSink`에 보낸다.

장점은 동시 발화에서도 원격 강의를 잃지 않는다는 점이다. 단점은 Zoom SDK 의존성, 권한·라이선스·배포 조건을 별도로 검토해야 한다는 점이다.

### 선택 B: 로컬 마이크 참조 신호로 오디오 단계에서 제거

ZoomCaption이 물리 마이크를 별도 참조로 읽고, 이를 저장 목적이 아니라 로컬 음성 검출과 제거에만 사용한다.

```text
물리 마이크 ─► 짧은 메모리 링버퍼 ─► 지연/게인 추정 ─┐
                                                     ▼
Zoom 출력 탭 ───────────────────────────────► 적응형 제거기
                                                     │
                                      정제된 강의 PCM만
                                           ├► 실시간 전사
                                           └► WAV/Whisper
```

구현 원칙은 다음과 같다.

- 두 입력을 같은 monotonic host time으로 타임스탬프한다.
- 5~10초 길이의 메모리 링버퍼만 유지하고 마이크 원본은 기본적으로 디스크에 저장하지 않는다.
- cross-correlation으로 Zoom 탭에 나타난 로컬 음성의 지연을 찾는다.
- NLMS 같은 적응형 필터로 Zoom의 게인·필터 변형을 추정해 로컬 성분만 뺀다.
- 원격 발화와 로컬 발화가 겹치는 `double-talk` 구간에는 필터 계수 학습을 멈춰 원격 음성을 따라가며 지우지 않게 한다.
- 제거 신뢰도가 낮을 때의 정책을 명시한다. 개인정보 우선 모드는 해당 짧은 구간을 전사에서 제외하고, 강의 보존 우선 모드는 원본을 통과시키되 “로컬 음성 혼입 가능” 표시를 남긴다.

이 처리는 반드시 `lecture.feed(...)`와 `recordingAudioArchive.write(...)` **앞**에서 해야 한다. 실시간 전사만 막으면 저장 WAV에서 Whisper가 로컬 음성을 다시 만들어 낸다.

### 선택 C: 텍스트 단계의 보조 완화책

오디오 제거가 어려우면 마이크를 별도 실시간 전사하고, 시간 구간과 텍스트 유사도가 모두 높은 강의 세그먼트를 로컬 발화로 표시해 제외할 수 있다. 현재 `Track.me`가 과거 호환용으로 남아 있어 데이터 모델의 출발점은 있다.

이 방식은 다음 이유로 보조책이어야 한다.

- 짧은 감탄사나 전문용어는 텍스트 일치가 약하다.
- 동시 발화 때 교수 문장까지 삭제할 수 있다.
- 실시간 전사와 Whisper의 구간 경계가 다르므로 시간 정렬이 필요하다.
- WAV 자체에는 로컬 음성이 계속 남는다.

## 5. 적용할 코드 구조

수정 시에는 Boolean과 축약 이름을 늘리지 말고 역할이 드러나는 타입과 변수명을 사용한다. 주요 구조는 다음과 같다.

```text
ZoomAudioProcessResolver
  └─ 회의 출력 후보 탐색 및 Core Audio process-list 변경 감시

AudioCaptureRouteSnapshot
  └─ 실제 선택된 프로세스·출력 장치·stream·포맷 기록

SystemAudioTap.start(captureRoute:)
  └─ 명시된 경로만 탭 생성; 대상 없음은 오류/대기, 전역 폴백 금지

AudioCaptureRouteMonitor
  └─ Zoom process object 또는 출력 장치 변경 시 탭 재생성

LocalMicrophoneReferenceFilter   (같은 스트림일 때만)
  └─ 짧은 메모리 참조로 로컬 성분 제거, 원본 마이크 비저장
```

각 타입에는 “무엇을 하는가”보다 “왜 이 계층이 필요한가”, “어떤 실패를 막는가”, “스레드와 수명주기를 누가 소유하는가”를 주석으로 남겨야 한다. 특히 오디오 콜백에서는 긴 잠금, 파일 탐색, 로그 포맷팅을 하지 않고 미리 준비한 상태만 읽어야 한다.

## 6. 시험 계획

### 필수 환경 조합

| 항목 | 조합 |
|---|---|
| 실행 모드 | 일반 / 관리자 실시간 캡처 |
| 실행 순서 | Zoom 먼저 / ZoomCaption 먼저 |
| 마이크 | 끔 / 켬 |
| 원격 음성 | 없음 / 있음 |
| 출력 장치 | 내장 스피커 / 유선 또는 Bluetooth 이어폰 |
| Zoom 기능 | 일반 회의 / 마이크 테스트 |
| 발화 | 로컬만 / 원격만 / 동시 발화 |

이어폰 시험은 실제 스피커 소리가 마이크를 거쳐 상대방에게 되돌아오는 음향 에코와 앱 내부 라우팅을 구분하는 데 필요하다. 내장 스피커에서만 나타나고 이어폰에서는 사라지면 상대방 에코 또는 음향 피드백 가능성이 높다. 두 환경에서 모두 같은 로컬 음성이 탭에 들어오면 Zoom/Core Audio 내부 경로 가능성이 높다.

### 합격 기준

1. 일반 모드에서 Zoom 대상이 없으면 캡처 프레임 수가 늘지 않고 “Zoom 대기” 상태가 표시된다.
2. Zoom 마이크를 켜고 로컬 사용자만 말한 30초 동안 `lecture`의 volatile/final 문장과 Whisper 문장이 생성되지 않는다.
3. Zoom 마이크를 켜거나 꺼도 원격 참가자 30초 표본의 캡처 시간과 전사 결과가 유지된다.
4. 로컬·원격 동시 발화에서도 원격 문장 손실률이 허용 기준 안에 든다.
5. 로그만으로 `zoomMeetingOutput`, `administratorSystemOutput`, `waitingForZoom` 중 어느 상태였는지 판별할 수 있다.
6. 출력 장치 또는 Zoom 프로세스 객체가 바뀌면 전역 캡처로 넓어지지 않고 제한된 경로로 재연결된다.
7. 마이크 참조 방식을 도입한다면 마이크 원본 파일이 생성되지 않고, 짧은 메모리 버퍼가 수명 종료 시 폐기된다.

## 7. 우선순위와 예상 효과

| 우선순위 | 작업 | 해결하는 위험 | 단독으로 마이크 유입 해결 보장 |
|---|---|---|---|
| P0 | 전역 폴백 제거, 명시적 대기 | Zoom 탐색 실패 시 모든 시스템 출력 유입 | 아니오 |
| P0 | 캡처 경로 스냅샷과 로그 | 재현 후 원인 판별 불가 | 진단용 |
| P1 | `us.zoom.xos` + device UID + stream으로 범위 제한 | 불필요한 Zoom helper/다른 출력 스트림 유입 | 스트림이 분리돼 있으면 예 |
| P1 | 관리자 A/B 소스 식별 시험 | 추측에 따른 잘못된 allowlist 수정 | 진단용 |
| P2 | Zoom의 분리된 수신 오디오 사용 | 같은 stream에 섞인 로컬 음성 | 가능하면 가장 확실 |
| P2 | 마이크 참조 기반 제거 | 같은 stream에 섞인 로컬 음성 | 튜닝·동시 발화 검증 필요 |
| P3 | 텍스트 중복 판정 | 자막에서 보이는 로컬 발화 완화 | 아니오, 보조책 |

## 8. 함께 정리해야 할 문서·설정 불일치

현재 README에는 “마이크는 기록하지 않습니다”라고 되어 있다. 앱이 물리 마이크 장치를 직접 열지 않는다는 뜻으로는 맞지만, 사용자가 기대하는 “내 목소리가 결과에 절대 들어가지 않는다”는 보장은 현재 구조가 제공하지 못한다. 수정 전까지는 다음처럼 정확히 표현해야 한다.

```text
ZoomCaption은 물리 마이크를 직접 캡처하지 않습니다.
다만 Zoom이 로컬 음성을 출력 스트림에 포함하면 Zoom 출력 캡처에 섞일 수 있습니다.
```

또한 `Info.plist`의 마이크 권한 설명은 “내 질문을 별도 트랙으로 기록”한다고 되어 있지만 현재 코드에는 그 기능이 없다. 마이크 참조 제거 기능을 구현하지 않을 경우 이 사용 설명 키를 제거해야 한다. 구현할 경우에는 “로컬 음성을 강의 캡처에서 제외하기 위한 기기 내 참조 신호”처럼 실제 목적에 맞게 바꾸고, 기본 비활성·원본 비저장 정책을 UI에 밝혀야 한다.

## 9. 최종 판단

지금 바로 특정 bundle ID 하나를 빼는 것만으로 고치는 것은 안전하지 않다. 현재 실행에서 실제 Zoom 회의 출력 후보는 `us.zoom.xos`이고, 이미 이 프로세스 하나만 선택됐을 가능성이 높다. 이를 제외하면 마이크뿐 아니라 강의도 함께 사라질 수 있다.

따라서 구현 순서는 다음으로 고정하는 것이 적절하다.

1. 일반 모드의 전역 폴백을 제거한다.
2. 실제 선택한 프로세스·장치·스트림을 기록한다.
3. 관리자 A/B 시험으로 로컬/원격 신호의 프로세스와 스트림 위치를 확인한다.
4. 분리돼 있으면 원격 출력 경로만 allowlist한다.
5. 같은 스트림이면 Zoom의 분리 오디오 소스 또는 명시적 마이크 참조 제거를 적용한다.
6. 실시간 전사와 Whisper 양쪽에서 동일한 정제 PCM을 사용해 회귀 시험한다.

이 순서라면 현재 강의 캡처를 잃지 않으면서, 마이크 유입이 라우팅 오류인지 이미 혼합된 신호인지 증거로 나눈 뒤 정확한 해결책을 적용할 수 있다.

## 10. 참고 자료

- Apple, [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- Apple, [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- Apple, [init(stereoMixdownOfProcesses:)](https://developer.apple.com/documentation/coreaudio/catapdescription/initstereomixdownofprocesses%3A?changes=_1&language=objc)
- Apple, [init(processes:deviceUID:stream:)](https://developer.apple.com/documentation/coreaudio/catapdescription/init%28processes%3Adeviceuid%3Astream%3A%29)
- Apple, [CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- Zoom, [Testing your audio settings for Zoom meetings](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0062765)

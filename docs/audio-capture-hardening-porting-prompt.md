# 다른 프로젝트용 프롬프트 — Zoom 오디오 캡처 무음/마이크 혼입 개선 이식

아래 내용을 다른 Codex·Claude 세션에 그대로 전달한다.

---

이 프로젝트에 ZoomCaption의 오디오 캡처 안전성 변경을 이식해라. 먼저 대상 프로젝트의
현재 시작/정지 수명주기와 Core Audio 탭 구성을 끝까지 읽고, 이름만 비슷한 코드를
기계적으로 복사하지 마라.

## 반드시 지킬 원칙

1. 수정하는 모든 코드에는 구현 내용보다 **왜 필요한지, 어떤 경쟁·오탐을 막는지**를
   설명하는 자세한 주석을 달아라.
2. `desc`, `targets`, `playing`, `gen` 같은 축약 이름 대신
   `captureTapDescription`, `zoomAudioProcessCandidates`,
   `processesWithActiveOutputIO`, `captureRouteGeneration`처럼 의미가 드러나는 이름을 써라.
3. 실사용 프로세스를 정지하거나 재시작하지 마라. 테스트는 관리자 모드, 임시 저장
   디렉터리, 별도 포트에서만 수행하라.
4. SpeechTranscriber와 Whisper는 독립적으로 유지하라. 전자는 즉시 자막, 후자는
   60~90초 지연 정확한 재전사다.
5. 기존 180초 강의 경계의 `lastNonSilentAt`, Archive flush, Whisper idle 대기,
   동일 무음 재검증, 안전한 volatile 정리 로직을 바꾸지 마라.
6. 오디오 정규화·게인·노이즈 필터·마이크 파형 상쇄를 추가하지 마라. 선택된 경로의
   원본 PCM을 두 전사기에 동일하게 전달하라.

## 현재 확인된 원인

- `kAudioProcessPropertyIsRunningOutput`은 프로세스에 실행 중인 출력 I/O와 활성
  출력 스트림이 있다는 뜻이다. 실제 audible sample이 있다는 뜻이 아니다.
- 이 값을 `isPlaying`으로 해석해 0 PCM 30초와 결합하면 정상적인 발표자 침묵을
  권한·탭 장애로 오탐한다.
- `CATapDescription(stereoMixdownOfProcesses:)`는 지정 프로세스의 출력 스트림을
  먼저 하나로 섞는다. 로컬 마이크 신호가 Zoom 출력에 나타나면 혼합 뒤에는 원격
  음성과 구별할 출처 정보가 없다.
- Zoom 후보가 없을 때 `stereoGlobalTapButExcludeProcesses: []`로 자동 전환하면
  Zoom 전용이라는 사용자의 기대와 달리 시스템 전체 소리를 녹음한다.

## 1단계 — 시작을 fail-closed로 만든다

`start()`가 현재 자원을 한 번에 준비하고 탭 생성 실패를 throw하는 구조라면
`waitingForZoom` 재시도 상태를 억지로 넣지 마라.

1. Boolean `zoomOnly` 대신 다음처럼 범위를 명시하라.

   - `zoomMeetingOutput`
   - `administratorSystemOutput`

2. 일반 모드는 Zoom 오디오 후보가 없으면 구체적인 오류로 즉시 실패시켜라.
3. 관리자 시스템 캡처만 명시적인 전역 탭을 허용하라.
4. 값싼 후보 preflight를 전사기·Archive·Whisper 준비 전에 실행하되, 탭 생성 시에도
   다시 검증해 TOCTOU 경쟁에서 전역 폴백이 생기지 않게 하라.
5. 실제 탭 성공 뒤에만 Store의 녹음 시계와 공유 자원을 commit하라.
6. 탭 생성 실패 시 다음을 모두 되돌려라.

   - 부분 생성된 tap/aggregate/IOProc
   - WhisperLive와 SentenceReconstructor
   - AudioArchive와 TrackTranscriber
   - audio sink와 활동/heartbeat 참조
   - 녹음 세대와 비동기 강의 경계 작업
   - Store의 `startedAt`

실패 rollback에서 일반 `endRecording()`이 time base를 증가시킨다면 사용하지 말고,
입력이 시작되지 않은 상태만 되돌리는 별도 취소 동작을 만들어라.

자동 `waitingForZoom`이 제품 요구사항이라면 별도 리팩터링으로 처리하라. 최소한
`idle`, `preparing`, `waitingForZoom`, `recording`, `stopping` 상태가 필요하다.
`waitingForZoom`에서는 running을 true로 두거나 Transcriber·Archive·Whisper를 만들지
말고 불변 시작 요청만 보관하라. 취소 가능한 감시 Task와 요청 UUID 재검증도 필요하다.

## 2단계 — 콘텐츠 무음과 콜백 중단을 분리한다

1. 기존 `AudioActivityClock`은 실제 PCM 활동과 180초 경계만 담당하게 유지하라.
2. 별도 `AudioCaptureHeartbeat`를 만들고 0 PCM을 포함한 모든 유효 Core Audio
   버퍼마다 monotonic uptime을 갱신하라.
3. `isPlaying`은 `hasActiveOutputIO`로 이름과 주석을 바로잡아라. 이 값만으로 오류
   팝업을 만들지 마라.
4. 다음 상태를 구분하라.

   - 콜백 최신 + 최근 유효 음성: 정상 수신
   - 콜백 최신 + 30초 이상 0 PCM: 정상 콘텐츠 무음
   - 최근 콜백 없음: callback stalled
   - 시작 때 선택한 Zoom 대상 없음: target lost
   - 출력 변경 직후 콜백 중단: route changed

5. 정상 콘텐츠 무음에는 빨간 오류 배너를 띄우지 마라.
6. 콜백 중단과 캡처 대상 소실은 각각 수 초 간격으로 두 번 연속 확인한 뒤 알리고,
   복구·정지 때 배너와 연속 확인 횟수를 명시적으로 지워라.
7. 실제 탭의 180초 경계는 콜백이 살아 있고 대상이 남아 있을 때만 허용하라.
8. 파일 끝 뒤 180초 경계를 시험하는 관리자 WAV 되먹임은 실제 탭을 우회하므로
   heartbeat가 없다는 이유로 막지 마라.

## 3단계 — 로그를 프로세스별로 분리한다

관리자와 실사용 프로세스가 같은 날짜 로그 파일을 각자의 FileHandle로 쓰지 않게 하라.
`zoomcaption-<date>-<live|admin>-pid-<pid>.log`처럼 역할과 PID가 포함된 파일을 사용하고,
prune이 현재 프로세스의 열린 파일을 삭제하지 않게 실제 파일명을 기억하라. 다른
live/admin 프로세스가 같은 날 계속 쓸 수 있으므로 오늘 날짜의 모든 역할·PID 로그와
날짜만 쓰던 기존 로그도 정리 대상에서 제외하라. 현재 날짜·파일명이 정해지기 전에
prune을 먼저 실행해서도 안 된다.

캡처 시작 로그에는 scope, PID, AudioObjectID, bundle ID, 장치 UID, 시스템 전체 캡처
여부, 자동 전역 폴백 여부를 남겨라.

## 4단계 — 운영 Resolver보다 관리자 A/B probe를 먼저 만든다

A/B 전에는 `ZoomAudioRouteResolver`의 최종 이름·타입·시그니처를 확정하지 마라.
`CATapDescription(processes:deviceUID:stream:)`도 운영 설계가 아니라 진단 후보다.

관리자 probe는 다음 조건을 지켜라.

- 운영 녹음이 정지한 관리자 인스턴스에서만 실행
- `us.zoom.*` 오디오 프로세스와 현재 출력 장치·stream index 열거
- 프로세스 전체 탭과 장치·스트림 탭을 하나씩 선택 가능
- 오디오는 저장하거나 전사하지 않고 callback count, 최근 callback 간격, peak,
  RMS, non-silent buffer ratio만 집계
- 일반 녹음이 시작되면 실행 중인 probe를 먼저 종료

시험은 헤드폰을 끼고 각 경로를 초기화한 뒤 수행한다.

1. 원격 음성만 재생하고 로컬 마이크 끔
2. 원격 음성을 멈추고 로컬 마이크로 고유 문구 발화
3. 원격 음성과 로컬 마이크 동시 발화
4. 출력 장치 변경 뒤 반복

## 5단계 — A/B 결과에 따라서만 운영 경로를 결정한다

- 전역 폴백에서만 혼입되면 폴백 제거로 끝내고 Resolver를 추가하지 마라.
- 특정 Zoom 프로세스에서만 로컬 음성이 나오면 검증된 회의 프로세스만 선택하라.
- 같은 프로세스지만 장치·스트림이 다르면 그때만 device UID와 stream index 기반
  운영 경로를 설계하라.
- 원격과 로컬 음성이 같은 process/device/stream에 이미 섞여 있으면 Core Audio
  Resolver 구현을 중단하라. WAV에서도 로컬 음성 배제가 필수일 때만 참가자별
  userID를 제공하는 Zoom Meeting SDK raw audio 아키텍처를 별도로 검토하라.

## 검증 조건

- 빌드 성공 및 JavaScript 문법 검사
- 정상 30~179초 침묵에 빨간 팝업 없음
- 180초 정상 침묵에 기존 경계 정확히 한 번
- 콜백 중단 중에는 180초 경계 없음
- Zoom 후보가 없으면 전역 캡처 없이 시작 실패 및 모든 상태 rollback
- 관리자와 실사용 로그 파일 분리
- A/B probe의 프로세스 전체 및 장치·스트림 측정 모두 콜백 수신
- 사용자가 마이크 on/off A/B를 끝내기 전에는 마이크 혼입 해결 완료라고 보고하지 않음

마지막 보고에는 확정된 사실, 아직 사람의 A/B가 필요한 부분, 실행한 격리 테스트와
그 결과, 건드리지 않은 기존 변경 사항을 구분해서 적어라.

---

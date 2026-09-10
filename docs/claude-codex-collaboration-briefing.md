# ZoomCaption — Claude·Codex 협업 배경 브리핑

이 문서는 새 Codex 세션(또는 다른 협업 에이전트)에게 지금까지 이 프로젝트에서 무엇을 했고 왜
그렇게 했는지 전달하기 위한 것이다. `docs/lecture-boundary-porting-prompt.md`가 특정 기능 하나의
스펙이었다면, 이 문서는 그 배경이 된 프로젝트 전체의 맥락이다 — 다른 프로젝트로 이식하려는
게 아니라, Claude와 Codex가 같이 이 프로젝트를 이끌어가기 위한 공유 컨텍스트다.

## 이 프로젝트가 뭔가

ZoomCaption은 macOS 메뉴바 앱이다. 강의를 실시간 자막(SpeechTranscriber, 빠르지만 부정확)과
Whisper 지연 재전사(60~90초 뒤, 느리지만 정확) 두 트랙으로 동시에 받아 적고, NLContextualEmbedding
기반 문단화로 묶고, 필요하면 Ollama/Qwen으로 용어를 교정한다. **사용자는 이 앱으로 실제 대학
강의·부트캠프를 녹음하는 1인 개발자다 — 장난감 프로젝트가 아니라 진짜 데이터가 걸려 있다.**

## 최우선 안전 수칙

- **라이브 앱을 녹음 중에 절대 재시작·종료하지 않는다.** 어떤 조작 전에도 `curl
  localhost:8765/api/sync`로 `running` 상태를 먼저 확인한다.
- **모든 테스트는 관리자 모드 격리 인스턴스로 한다**: `--admin --dir <스크래치 폴더> --port
  <새 포트>`. `/api/admin/feed`로 WAV 파일을 배속 재생해 실제 파이프라인을 재현한다.
- **저장 위치(`StorageLocation`, `UserDefaults` 기반)는 앱 번들 ID로 묶여 있어 포트를 바꿔도
  실제 앱과 같은 값을 공유한다** — `--dir`로 파일 위치는 격리되지만 `UserDefaults`는 안 된다.
  `--admin` 모드는 `StorageLocation`을 아예 안 읽어서 안전하고, 비관리자 경로를 테스트해야
  하면 `-storageLocation <스크래치 경로>` 커맨드라인 인자(Foundation의 `NSArgumentDomain`,
  디스크에 안 남는 임시 오버라이드)를 쓴다 — 절대로 그냥 `--admin` 없이 띄워서 진짜
  `UserDefaults` 값을 읽거나 덮어쓰지 않는다.
- **커밋은 명시적으로 요청받았을 때만** 한다.
- **코딩 스타일 두 가지, 예외 없음**: (1) 새/수정 코드에는 왜 이렇게 짰는지, 어떤 경쟁
  상태·엣지 케이스를 막는지 설명하는 주석을 단다. (2) `x`, `tmp`, `flag` 같은 축약 대신
  역할이 드러나는 변수·함수명을 쓴다.

## 지금까지 한 일

### 1. 오디오 전처리 조사 — 결론: 원본을 그대로 쓰는 게 최선

EQ 필터(하이패스/로우패스 여러 컷오프), 정적 게인, `dynaudnorm`(실시간·피크 기반), 1-pass/2-pass
`loudnorm`(true LUFS)까지 **네 가지 서로 다른 방법**을 실제 강의 오디오로 테스트했다. 공통 결론:

- 측정을 더 정교하게 해도(크루드한 평균 볼륨 → K-weighting 기반 True LUFS) 오류율은 안 줄었다.
- 위험은 보정폭에 비례한다 — 8~11dB만 필요한 세션은 항상 안전했고, 24dB 이상 필요한 조용한
  세션만 방식과 무관하게 계속 무너졌다.
- 파라미터(LUFS의 `I`, `TP` 등)를 아무리 튜닝해도 오류 총량은 안 줄고 어떤 단어가 틀리는지만
  바뀌었다.
- "쪼는→쫓는", "울산일→월사일", "남궁도→남분도", 특정 문장의 완전한 환각("늙어서" 관련)은
  테스트한 거의 모든 조합에서 예외 없이 재발했다 — 처리 방식과 무관한 근본적 불안정.
- "When De-noising Hurts" 논문이 말하는 도메인 미스매치(종단간 ASR이 원본 그대로의 다양한
  잡음 환경에서 학습됐기 때문에, 입력을 사후에 "깨끗하게" 만드는 것 자체가 모델엔 낯선
  입력이 된다는 설명)와 실측 방향이 일치한다.
- 프로토타입으로 실시간 부트스트랩→누적 RMS 하이브리드 정규화기(`LoudnessNormalizer`)까지
  실제로 구현·단위테스트했지만, 위 결론에 따라 **채택하지 않고 완전히 롤백**했다 — 코드베이스에
  안 남아 있다.
- **앞으로 오디오 전처리(필터링/정규화)를 다시 제안하지 말 것** — 이미 여러 방법으로 검증하고
  버린 방향이다.

### 2. 세션 저장 구조

**개념 분리**: `Options.baseDir`(CLI `--dir`, 관리자 모드 전용) vs `StorageLocation.current`
(`UserDefaults` 기반 영구 설정, 실사용 기본값) vs `store.sessionDir`(지금 이 세션이 실제로
쓰는 폴더, 세션 생성 시 한 번 정해짐). 세 개념을 분리한 이유와 장단점을 깊이 논의한 뒤 아래
기능들을 구현했다.

**"다른 위치에서 열기" 기능** — 세션 탭에 버튼 추가, 기존 `/api/pickFolder` + `/api/session/open`
을 그대로 재사용(백엔드 변경 없음). `baseDir` 밖 임의 위치의 세션도 열고 이어서 저장할 수 있다.

**저장 위치 영구화 + 관리자 게이트 + 삭제 + 목록 5개 제한** (`StorageLocation.swift` 신규,
`ensureSessionDir()`/`effectiveBaseDir` 로 세션 폴더 생성 지점 10곳 통합):
- `StorageLocation.current`: 첫 접근 시 기존 기본 경로(`~/Documents/ZoomCaption`)를 그대로
  시드값으로 영구 저장(마이그레이션, 기존 아카이브 안 사라짐).
- `--dir`는 `--admin` 없이 쓰면 `exit(1)`로 즉시 거부(조용한 폴백이 아니라 시끄러운 실패 —
  테스트 격리 안전장치가 미래에 조용히 무력화되는 걸 막기 위해).
- `POST /api/session/delete`: `FileManager.trashItem`(복구 가능한 휴지통, 완전 삭제 아님) —
  세션 폴더엔 원본 강의 음성도 들어있어서. 녹음 중·현재 열린 세션은 삭제 거부.
- `SessionStore.list(base:limit:)`: 최근 5개만.
- 설정 탭 "저장 위치" 필드가 이제 진짜 영구 값을 보여주고, 고르는 즉시 저장된다.

### 3. 180초 무음 강의 경계 + 정지 시 10분 미만 예외

**이미 있던 기능**(어제 커밋 `64046db`, 안 건드림): 마지막 유효 소리 이후 180초 무음이면
녹음은 안 멈추고 강의 한 단위만 마무리한다(`AudioActivityClock`의 `lastNonSilentAt` 절대
시각 기반, 카운터 없음). `commitLectureBoundary`가 취소·재검증·pending 오디오 flush·Whisper
`waitUntilIdle`까지 전부 방어한다 — 이미 검증된 코드라 로직을 바꾸지 않았다.

**이번에 새로 추가한 것**: 정지 버튼을 눌러도 자연스럽게 경계가 생기는 게 맞지만(요약
시스템의 근간), **열린 구간이 10분(600초) 미만이면 경계 표식을 안 붙인다** — 정지는 "문제가
생겼거나 강의가 끝났을 때" 눌리므로, 10분도 안 되는 꼬리를 독립된 강의 단위로 요약 시스템에
넘기는 건 의미가 없다. 전사 자체는 이 판단과 무관하게 항상 완료된다.

- `TranscriptBoundary`에 `.recordingStopped` 케이스 추가(기존 `.lectureEnded`와 나란히).
- `markLatestSegmentAsLectureEnded(after:reason:)`로 일반화(`reason` 기본값 `.lectureEnded`라
  기존 180초 호출부는 무수정).
- **실제로 버그를 하나 잡고 고쳤다**: "열린 구간"의 기준점을 처음엔 "마지막으로 문단 번호가
  매겨진 세그먼트의 끝"으로 짰는데, 문단 번호는 녹음 내내 실시간으로 계속 매겨져서(11분
  실측 클립 하나에서 문단 23개) 이 기준으로는 열린 구간이 항상 몇 초로 계산돼 10분 문턱을
  절대 못 넘었다. **"마지막으로 이미 구조화 경계(`boundaryAfter`)가 붙은 세그먼트의 끝"**으로
  바꿔야 맞다 — `lastClosedTranscriptUnitEnd(after:)`. 이 기준점은 `store.finalizeParagraphs()`
  호출 **전에** 캡처해야 한다(그 뒤엔 모든 꼬리에 번호가 강제로 매겨져 기준을 잃는다).
- 관리자 모드 격리 인스턴스로 실제 11분 분량 실전사(99개 세그먼트)를 돌려 검증: 짧은 세션(2분)
  → 경계 없음, 긴 세션(11분) → `recordingStopped` + "녹음 종료" 라벨 정확히 부착 확인.

### 4. Claude·Codex 협업 체제

Codex CLI(`codex-cli`, 이미 설치·ChatGPT 로그인 완료 상태였음)를 `claude mcp add codex -s user
-- codex mcp-server`로 전역 등록. 위 3번 기능은 계획(Claude) → 구현(Codex, `mcp__codex__codex`
MCP 툴, `cwd`를 프로젝트 루트로 `sandbox: workspace-write`) → 검수(Claude, `git diff` 직접
확인 + 관리자 모드 실측)로 진행했다. **Codex의 로컬 `swift build`는 자체 샌드박스의 SDK
버전 불일치로 늘 실패했다** — Claude가 같은 코드를 자신의 환경에서 직접 빌드해서 확인했다.
Codex가 짠 코드 자체(변수명, 주석, 로직)는 품질이 좋았고, 실제로 잡은 버그(위 3번의 기준점
문제)는 Codex 구현 문제가 아니라 Claude가 처음 짠 계획 자체의 설계 결함이었다.

## 검증 방법론 (재사용할 것)

1. `swift build -c release`로 컴파일 확인.
2. `curl localhost:8765/api/sync`로 라이브 앱 `running`/`boot` 확인.
3. `--admin --dir <스크래치> --no-open --port <새 포트>`로 격리 인스턴스 실행.
4. `POST /api/admin/feed {path, title, speed}`로 실제(또는 실측 아카이브에서 잘라낸) WAV를
   배속 먹인다 — 짧은 톤/무음이 아니라 **실제 발화가 있는 오디오**를 써야 Whisper가 진짜
   문장을 만든다.
5. 피드가 끝났는지 로그로 확인할 땐 "관리자 되먹임 **끝까지 보냄/중단됨**"까지 정확히
   매칭한다 — "관리자 되먹임"만 grep하면 시작 로그에 걸려서 피드 중간에 정지를 불러버리고
   (그러면 `adminFeed.stop()`이 진행 중이던 피드를 끊는다), 이걸 실제로 한 번 겪었다.
6. `POST /api/stop`은 내부적으로 Whisper 잔여 큐를 최대 180초까지 기다린다 — 그보다 오래
   실시간으로(폴링하며) 기다리면, 그 사이 새 오디오 프레임이 하나도 안 들어오는 게(admin
   feed는 파일이 끝나면 완전히 멈춤) 진짜 180초 무음으로 잡혀 **기존 무음 경계 기능이 먼저
   발동**할 수 있다 — 이것도 실제로 한 번 겪었다. 새 기능만 깨끗하게 보려면 피드가 끝나자마자
   바로 정지를 부르는 쪽이 안전하다.
7. 결과는 `session.json`을 직접 열어 `whisperSegments`의 `boundaryAfter`/`paragraph` 등을
   확인한다.
8. 끝나면 격리 인스턴스 종료, 라이브 앱 `boot` 불변 재확인.

## 지금 코드베이스에서 알아둘 핵심 파일

- `Sources/ZoomCaption/App/ZoomCaptionApp.swift` — 앱 전체 상태·수명주기(`start()`/`stop()`),
  180초 경계 파이프라인(`beginLectureBoundaryIfNeeded`/`applyLectureBoundary`/
  `commitLectureBoundary`), `effectiveBaseDir`/`ensureSessionDir()`.
- `Sources/ZoomCaption/Storage/Store.swift` — `TranscriptStore`(세그먼트·문단·경계 관리),
  `TranscriptBoundary` enum, `Segment.boundaryAfter`.
- `Sources/ZoomCaption/Storage/Session.swift` / `StorageLocation.swift` — 디스크 저장 형식,
  영구 저장 위치.
- `Sources/ZoomCaption/Audio/AudioTap.swift` — `AudioActivityClock`(무음 감지의 실제 시계).
- `Sources/ZoomCaption/Audio/AudioArchive.swift` — `pending` 버퍼, `onChunk`, VAD 분할.
- `Sources/ZoomCaption/Transcription/WhisperLive.swift` / `SentenceReconstructor.swift` —
  Whisper 작업 큐, 문장 재구성.
- `Sources/ZoomCaption/Analysis/Paragraph.swift` — 문단 경계 판정(임베딩 코사인 유사도, 시간
  무관·순전히 문장 순서 기반).
- `Sources/ZoomCaption/Server/WebUI+Script.swift` / `WebUI+Markup.swift` / `WebUI+Style.swift`
  — 프론트엔드(전부 Swift 문자열 리터럴로 컴파일됨, 별도 정적 파일 없음).
- `docs/lecture-boundary-porting-prompt.md`, `docs/whisper-silence-stall-analysis.md` — 180초
  경계 기능 자체의 설계 스펙과 근본 원인 분석.

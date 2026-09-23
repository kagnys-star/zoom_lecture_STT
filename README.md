# ZoomCaption

Zoom 수업의 소리를 실시간 자막으로 보고, 더 정확한 기록과 요약까지 남기는 macOS 앱입니다.

- Zoom 오디오를 직접 받아 자막으로 변환합니다.
- 빠른 실시간 자막과 정확한 Whisper 기록을 함께 제공합니다.
- 자막 검색, 편집, 세션 이어 적기, Markdown·SRT 내보내기를 지원합니다.
- Zoom의 내부 오디오 경로가 바뀌면 대상을 다시 확인하고 자동으로 재연결합니다.
- 음성과 로컬 요약 데이터는 기본적으로 이 Mac 안에서 처리됩니다.
- BlackHole 같은 가상 오디오 드라이버가 필요하지 않습니다.

> ZoomCaption은 메뉴 막대나 Dock에 상주하지 않는 로컬 앱입니다. 실행하면 브라우저에서
> `http://127.0.0.1:8765`가 열립니다.

## 시작하기

### 준비물

- Apple Silicon Mac
- macOS 26 Tahoe 이상
- Xcode Command Line Tools
- Homebrew 권장 — Whisper와 교안 분석 도구 설치에 사용합니다

Command Line Tools가 없다면 먼저 설치합니다.

```bash
xcode-select --install
```

### 1. 기본 설치

프로젝트 폴더에서 아래 명령을 한 번 실행합니다.

```bash
./setup.sh
```

설치 스크립트는 시스템 조건을 확인하고 다음 항목을 준비합니다.

- 실시간 자막 앱
- 자막 가독성을 위한 Pretendard 글꼴 — 다운로드에 실패하면 시스템 글꼴을 사용합니다
- 정확한 재전사용 Whisper와 모델
- 교안 용어 추출용 `mecab-ko` (Homebrew가 있을 때)
- `ZoomCaption.app` 빌드

로컬 Qwen 요약 모델은 용량이 크기 때문에 기본 설치에 포함하지 않습니다. 자막 녹음,
편집, 저장, 온라인 모델용 요약 프롬프트는 Qwen 없이도 사용할 수 있습니다.

### 2. 기존 설치 업데이트

이미 `setup.sh`로 설치해 사용 중이라면, 녹음을 마치고 ZoomCaption을 완전히 종료한 뒤
최신 소스를 받아 앱만 다시 빌드하면 됩니다.

```bash
git pull --ff-only
./build.sh
```

`build.sh`는 현재 소스로 `ZoomCaption.app`을 다시 만들고 애드혹 서명합니다. 새로 만들어진 앱을
실행해야 업데이트가 적용됩니다. 선택 글꼴이나 Whisper 같은 설치 도구까지 다시 확인하려면
`./setup.sh`를 실행하세요. 일반적인 코드 업데이트에는 `./build.sh`만 사용하면 됩니다.

### 3. 시스템 오디오 권한 허용

처음 실행하기 전에 다음 위치에서 ZoomCaption을 켭니다.

**시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록 → ZoomCaption**

권한이 없으면 macOS가 오류 대신 무음 데이터를 전달할 수 있습니다. 이 경우 앱은 자막 화면에
경고를 표시합니다. 앱을 다시 빌드하면 권한을 다시 허용해야 할 수 있습니다.

### 4. 실행

```bash
open ZoomCaption.app
```

브라우저가 열리면 Zoom 회의에 입장한 뒤 **녹음 시작**을 누르세요.

## 기본 사용법

1. 상단의 수업 제목을 확인하거나 바꿉니다.
2. 필요하면 오른쪽 **교안** 탭에 PDF를 넣습니다.
3. **녹음 시작**을 누릅니다.
4. 수업 중에는 아래쪽 실시간 자막으로 현재 발화를 확인합니다.
5. Whisper가 처리한 정확한 자막은 위쪽 기록에 순서대로 쌓입니다.
6. 수업이 끝나면 **녹음 정지**를 누르고 마무리가 끝날 때까지 기다립니다.
7. **세션** 탭에서 기록을 저장하거나 Markdown·SRT로 내보냅니다.

브라우저 탭을 닫아도 녹음은 계속됩니다. 녹음을 끝내려면 반드시 **녹음 정지**를 누르세요.
앱 자체를 끝내려면 오른쪽 위 전원 버튼 또는 **설정 → ZoomCaption 완전 종료**를 사용합니다.

## 화면 안내

### 자막

- **Whisper**: 30초 단위로 뒤따라오는 정확한 정식 기록입니다.
- **실시간**: 지금 말하는 내용을 빠르게 보여 줍니다. 화면에는 최근 내용만 남지만 전체 기록은 저장됩니다.
- **편집**: 줄을 눌러 수정합니다. `Enter`로 저장하고 `Esc`로 취소합니다.
- **검색**: 확정된 Whisper 자막에서 원하는 내용을 찾습니다.
- **글자 크기**: 작게·중간·크게 중 하나를 선택합니다.

### 교안

PDF를 넣으면 수업의 주요 용어를 찾아 음성 인식 힌트와 요약 용어집에 사용합니다. 원본 PDF의
크기 제한은 64MB입니다. `mecab-ko`가 없어도 동작하지만 용어 추출 정확도가 낮을 수 있습니다.

### 세션

기본 저장 위치는 `~/Documents/ZoomCaption/`입니다. 수업 하나마다 별도 폴더가 만들어지며,
기존 세션을 열어 뒤에 이어서 기록할 수도 있습니다.

```text
자료구조-3주차/
├── session.json          앱이 다시 여는 원본 데이터
├── audio_000000.wav      원본 소리 보관을 켰을 때 생성되는 오디오
├── transcript.md         요약과 전체 Whisper 기록
├── transcript.srt        영상 편집용 자막
├── transcript_live.md    전체 실시간 기록
└── 교안.pdf              업로드한 교안 사본
```

같은 세션에 이어 적으면 타임스탬프도 계속 이어집니다. 녹화 영상마다 시간이 0초부터 시작해야
한다면 회차별로 새 세션을 만드세요.

### 요약

요약 화면에서는 두 가지 방식을 선택할 수 있습니다.

- **로컬 모델**: 별도로 설치한 Qwen 3 8B가 이 Mac 안에서 요약합니다.
- **Claude · ChatGPT · Gemini**: 앱이 요약 프롬프트를 준비합니다. 선택한 서비스의 웹 화면에
  붙여넣어 사용하며, 이 경우 녹취 내용이 해당 서비스로 전달됩니다.

## 로컬 Qwen 요약 추가 설치

로컬 요약이 필요한 사용자만 아래 스크립트를 실행하세요.

```bash
./setup-qwen.sh
```

이 스크립트는 Ollama와 `qwen3:8b` 모델을 설치합니다. 모델 다운로드는 약 5GB이며 16GB 이상의
통합 메모리를 권장합니다. 설치 후에는 ZoomCaption이 요약할 때 Ollama를 자동으로 시작합니다.

설치 여부는 다음 명령으로 확인할 수 있습니다.

```bash
ollama list
```

## 저장과 개인정보

- 오디오 캡처, SpeechTranscriber, Whisper, Qwen 로컬 요약은 기기 안에서 처리됩니다.
- 기본 동작은 Zoom 오디오만 캡처하며 마이크는 기록하지 않습니다.
- **설정 → Whisper 처리 후 원본 소리 보관**을 끄면 정확한 자막을 만든 뒤 WAV 원본을 삭제합니다.
- Claude, ChatGPT, Gemini 요약을 선택하면 사용자가 직접 해당 서비스로 녹취 프롬프트를 보냅니다.
- 앱 서버는 외부에 공개되지 않고 `127.0.0.1`에서만 열립니다.
- 선택 글꼴은 `~/Library/Application Support/ZoomCaption/fonts/`에 저장되고 로컬 앱 서버에서만 제공됩니다.

## 문제가 있을 때

### 자막이 한 줄도 나오지 않아요

1. Zoom 회의에서 실제로 소리가 재생 중인지 확인합니다.
2. **화면 및 시스템 오디오 기록** 권한이 켜져 있는지 확인합니다.
3. 권한을 바꿨다면 ZoomCaption을 완전히 종료한 뒤 다시 실행합니다.
4. 상단 버튼이 **녹음 정지**로 표시되는지 확인합니다. **녹음 시작**이면 현재 녹음이 꺼진 상태입니다.
5. 앱의 **설정 → 문제 해결**에서 `대상 healthy`와 최근 버퍼 수신 시간이 표시되는지 확인합니다.

Zoom이 오디오 프로세스를 내부적으로 다시 만들면 ZoomCaption은 새 프로세스 정체성을 확인해
자동으로 재연결합니다. `replacementAvailable` 또는 대상 변경 경고가 계속되면 녹음을 정지했다가
다시 시작하세요. Zoom 후보가 없을 때 시스템 전체 소리로 조용히 전환하지는 않습니다.

### Whisper 자막이 만들어지지 않아요

기본 설치를 다시 실행해 Whisper 실행 파일과 모델을 확인합니다.

```bash
./setup.sh
```

### 로컬 요약을 사용할 수 없어요

추가 설치를 다시 실행한 뒤 모델이 보이는지 확인합니다.

```bash
./setup-qwen.sh
ollama list
```

### 앱을 다시 열었는데 이미 녹음 중이에요

브라우저 창만 닫으면 백그라운드 앱과 녹음은 계속됩니다. 기존 녹음 상태를 그대로 보여 주는 것이
정상입니다. 상단의 **녹음 정지**를 누르면 현재 세션을 마무리합니다.

## 관리자 진단

일반 사용자에게 필요하지 않은 오디오 A/B 테스트와 기록 대조 도구는 관리자 모드에만 표시됩니다.

```bash
./open-admin.command
```

관리자 모드는 일반 앱과 분리된 `127.0.0.1:8766` 포트와
`~/Documents/ZoomCaption-Admin/` 저장 폴더를 사용합니다. 라이브 수업 중에는 실제 탭 A/B probe를
필요한 경우에만 짧게 실행하고, 저장된 WAV 되먹임 테스트를 우선 사용하세요.

## 개발 및 확인

```bash
# 앱 빌드
./build.sh

# Web UI의 HTML·JavaScript 연결 계약 검사
swift run ZoomCaption --webui-check

# 요약 파이프라인 회귀 검사
swift run ZoomCaption --summary-check

# Core Audio 프로세스 정체성·objectID 재사용 회귀 검사
swift run ZoomCaption --audio-capture-check
```

주요 소스 위치:

- `Sources/ZoomCaption/Server/WebUI+Markup.swift` — 화면 구조
- `Sources/ZoomCaption/Server/WebUI+Style.swift` — 화면 스타일
- `Sources/ZoomCaption/Server/WebUI+Script.swift` — 화면 동작
- `Sources/ZoomCaption/App/ZoomCaptionApp.swift` — 앱 상태와 API
- `Sources/ZoomCaption/Audio/AudioTap.swift` — Zoom 프로세스 선택, 정체성 확인, 자동 재연결

배포용 서명과 공증은 `build.sh`의 애드혹 서명과 별도로 준비해야 합니다.

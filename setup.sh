#!/bin/bash
# ZoomCaption 설치 스크립트
# 처음 쓰는 Mac에서 한 번만 실행하면 됩니다.  ./setup.sh
set -uo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }

FATAL=0

bold "1. 시스템 확인"

OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$OS_MAJOR" -ge 26 ]; then
  ok "macOS $(sw_vers -productVersion)"
else
  bad "macOS $(sw_vers -productVersion) — 26(Tahoe) 이상이 필요합니다."
  warn "  음성 인식(SpeechAnalyzer)이 macOS 26에서 처음 나온 기능입니다."
  FATAL=1
fi

if [ "$(uname -m)" = "arm64" ]; then
  ok "Apple Silicon ($(sysctl -n machdep.cpu.brand_string))"
else
  bad "Intel Mac은 온디바이스 음성 인식이 지원되지 않습니다."
  FATAL=1
fi

if xcode-select -p >/dev/null 2>&1; then
  ok "Command Line Tools 설치됨"
else
  bad "Command Line Tools가 없습니다. 먼저 실행하세요:  xcode-select --install"
  FATAL=1
fi

# 빌드 자체는 Command Line Tools만으로도 됩니다(swift build, xcodebuild 없이).
# 다만 최신 macOS SDK 관련 오류가 나면 전체 Xcode가 필요할 수 있어 안내만 해둡니다.
DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -d /Applications/Xcode.app ]; then
  ok "Xcode 설치됨 ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Xcode.app/Contents/Info.plist 2>/dev/null || echo '버전 확인 불가'))"
  if [[ "$DEVELOPER_DIR" == *CommandLineTools* ]]; then
    warn "xcode-select가 아직 Command Line Tools를 가리킵니다. Xcode로 바꾸려면:"
    echo "      sudo xcode-select --switch /Applications/Xcode.app"
  fi
else
  warn "전체 Xcode 앱은 없습니다 (Command Line Tools만 설치됨)."
  warn "  지금은 이것만으로 빌드됩니다. 나중에 SDK 관련 빌드 오류가 나면"
  warn "  App Store에서 Xcode를 설치한 뒤 아래를 실행하세요:"
  echo "      sudo xcode-select --switch /Applications/Xcode.app"
  echo "      sudo xcodebuild -license accept"
fi

[ "$FATAL" = "1" ] && { echo; bad "필수 조건이 갖춰지지 않아 중단합니다."; exit 1; }

echo
bold "2. 한국어 형태소 분석기 (교안 PDF 용어 추출용)"

if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew가 없습니다. 설치하려면:"
  echo '      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  warn "없어도 앱은 동작합니다 (내장 규칙으로 용어를 뽑지만 정확도가 떨어집니다)."
else
  for pkg in mecab-ko mecab-ko-dic; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      ok "$pkg 이미 설치됨"
    else
      echo "  → $pkg 설치 중…"
      if brew install "$pkg" >/dev/null 2>&1; then ok "$pkg 설치 완료"; else warn "$pkg 설치 실패 (없어도 앱은 동작합니다)"; fi
    fi
  done
  # mecabrc 를 고치지 않고 앱이 -d 로 사전을 직접 지정하므로 별도 설정이 필요 없다.
  if [ -f /opt/homebrew/lib/mecab/dic/mecab-ko-dic/sys.dic ]; then
    ok "mecab-ko-dic 사전 확인"
  fi
fi

echo
bold "3. 자막 글자체 (Pretendard)"
# 시스템 폰트에만 기대면 macOS/Windows 브라우저마다 자막이 다르게 보입니다.
# 화면에서 빠르게 훑어 읽어야 하는 실시간 자막에 맞춰 가독성 위주로 설계된
# 무료(OFL) 폰트를 내려받아 웹 UI가 직접 서빙하게 합니다. 없어도 앱은 시스템
# 한글 폰트로 정상 동작합니다.
FONT_DIR="$HOME/Library/Application Support/ZoomCaption/fonts"
FONT_FILE="PretendardVariable.woff2"
FONT_VERSION="1.3.9"
FONT_SHA256="9599f12fd42fc0bce1cd50b47a0c022e108d7aa64dd0d1bb0ed44f3282d900b4"
font_checksum() { shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'; }
if [ -f "$FONT_DIR/$FONT_FILE" ] \
    && [ "$(font_checksum "$FONT_DIR/$FONT_FILE")" = "$FONT_SHA256" ]; then
  ok "Pretendard 확인"
else
  if [ -f "$FONT_DIR/$FONT_FILE" ]; then
    warn "기존 Pretendard 파일이 손상됐거나 예상 버전과 달라 다시 받습니다."
    rm -f "$FONT_DIR/$FONT_FILE"
  fi
  echo "  → Pretendard 내려받는 중… 약 2MB"
  mkdir -p "$FONT_DIR"
  if curl -fL --progress-bar -o "$FONT_DIR/$FONT_FILE.part" \
      "https://cdn.jsdelivr.net/npm/pretendard@$FONT_VERSION/dist/web/variable/woff2/$FONT_FILE"; then
    if [ "$(font_checksum "$FONT_DIR/$FONT_FILE.part")" = "$FONT_SHA256" ]; then
      mv "$FONT_DIR/$FONT_FILE.part" "$FONT_DIR/$FONT_FILE"
      ok "Pretendard 준비 완료"
    else
      rm -f "$FONT_DIR/$FONT_FILE.part"
      warn "Pretendard 무결성 검증 실패 (시스템 폰트를 사용합니다)"
    fi
  else
    rm -f "$FONT_DIR/$FONT_FILE.part"
    warn "Pretendard 내려받기 실패 (없어도 앱은 시스템 폰트로 동작합니다)"
  fi
fi

echo
bold "4. Whisper (정확한 자막)"
# 실시간 자막은 macOS 내장 엔진이 맡는다. Whisper 는 수업이 끝난 뒤
# 저장된 소리를 다시 들어 정확도를 끌어올리는 용도라 없어도 앱은 돈다.
if command -v whisper-cli >/dev/null 2>&1; then
  ok "whisper-cli 확인"
elif command -v brew >/dev/null 2>&1; then
  echo "  → whisper-cpp 설치 중…"
  brew install whisper-cpp >/dev/null 2>&1 && ok "whisper-cpp 설치 완료" \
    || warn "whisper-cpp 설치 실패 (재전사 기능만 못 씁니다)"
else
  warn "Homebrew 가 없어 whisper 를 건너뜁니다"
fi

WHISPER_DIR="$HOME/.cache/whisper"
WHISPER_MODEL="ggml-large-v3-turbo-q5_0.bin"
if [ -f "$WHISPER_DIR/$WHISPER_MODEL" ]; then
  ok "Whisper 모델 확인 ($WHISPER_MODEL)"
elif command -v whisper-cli >/dev/null 2>&1; then
  echo "  → 모델 내려받는 중… 약 547MB, 몇 분 걸립니다"
  mkdir -p "$WHISPER_DIR"
  if curl -fL --progress-bar -o "$WHISPER_DIR/$WHISPER_MODEL.part" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"; then
    mv "$WHISPER_DIR/$WHISPER_MODEL.part" "$WHISPER_DIR/$WHISPER_MODEL"
    ok "Whisper 모델 준비 완료"
  else
    rm -f "$WHISPER_DIR/$WHISPER_MODEL.part"
    warn "모델 내려받기 실패 — 나중에 setup.sh 를 다시 실행하세요"
  fi
fi

echo
bold "5. 빌드"
if ./build.sh >/tmp/zoomcaption-build.log 2>&1; then
  ok "ZoomCaption.app 생성 완료"
else
  bad "빌드 실패 — 로그: /tmp/zoomcaption-build.log"
  tail -20 /tmp/zoomcaption-build.log
  exit 1
fi

echo
bold "6. 남은 것 — 직접 해주셔야 합니다"
cat <<'GUIDE'
  ① 시스템 오디오 권한  (필수)
     시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록
     → ZoomCaption 을 켜세요.
     ※ 권한이 없으면 macOS가 오류 대신 '무음'을 흘려보내서
        자막이 한 줄도 안 생깁니다. 앱이 이 상태를 감지하면 경고를 띄웁니다.

  ② 한국어 인식 모델
     앱을 처음 켜면 필요 시 자동으로 내려받습니다. (보통 이미 설치되어 있음)
GUIDE

echo
bold "실행"
echo "  open $(pwd)/ZoomCaption.app"
echo
bold "선택 설치"
echo "  로컬 Qwen 3 8B 요약이 필요하면:  ./setup-qwen.sh"
echo "  자막 녹음과 편집은 Qwen 없이도 모두 사용할 수 있습니다."
echo

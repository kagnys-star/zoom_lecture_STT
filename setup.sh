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
bold "3. 요약 모델 (로컬 LLM)"

RAM_GB=$(($(sysctl -n hw.memsize) / 1073741824))
if [ "$RAM_GB" -ge 24 ]; then WANT_MODEL="qwen3:14b"; MODEL_SIZE="9GB"
elif [ "$RAM_GB" -ge 16 ]; then WANT_MODEL="qwen3:8b";  MODEL_SIZE="5GB"
else                           WANT_MODEL="qwen3:4b";  MODEL_SIZE="3GB"
fi
ok "메모리 ${RAM_GB}GB → 권장 모델 $WANT_MODEL (약 $MODEL_SIZE)"

if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew가 없어 Ollama를 설치할 수 없습니다. Apple 내장 모델로 요약합니다."
elif ! command -v ollama >/dev/null 2>&1; then
  echo "  → Ollama 설치 중…"
  brew install ollama >/dev/null 2>&1 && ok "Ollama 설치 완료" || warn "Ollama 설치 실패"
else
  ok "Ollama 이미 설치됨"
fi

if command -v ollama >/dev/null 2>&1; then
  if ! curl -s --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "  → Ollama 서버 시작 중…"
    nohup ollama serve >/tmp/ollama.log 2>&1 &
    sleep 4
  fi
  if curl -s --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    INSTALLED=$(curl -s http://127.0.0.1:11434/api/tags | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    if echo "$INSTALLED" | grep -qE '^(qwen3|exaone|gemma3|qwen2\.5)'; then
      ok "요약 모델 있음: $(echo "$INSTALLED" | head -1)"
    else
      warn "요약 모델이 없습니다. $WANT_MODEL 를 받으려면 (약 $MODEL_SIZE, 시간이 걸립니다):"
      echo "      ollama pull $WANT_MODEL"
      warn "받지 않아도 앱은 Apple 내장 모델로 요약합니다."
    fi
  else
    warn "Ollama 서버를 띄우지 못했습니다. 모델을 받으려면 'ollama serve' 후 'ollama pull $WANT_MODEL'."
  fi

  # Ollama 를 로그인 때마다 상주시킬 필요가 없다. 앱이 요약할 때만 알아서 띄운다.
  if brew services list 2>/dev/null | grep -q "^ollama *started"; then
    echo "  → Ollama 상시 실행(brew service)을 끕니다. 요약할 때 앱이 자동으로 띄웁니다."
    brew services stop ollama >/dev/null 2>&1 && ok "Ollama 상주 해제" || warn "상주 해제 실패"
  fi
fi

echo
bold "4. Whisper (재전사 — 선택)"
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

  ② Apple Intelligence  (권장)
     시스템 설정 → Apple Intelligence & Siri → 켜기
     → 요약 품질이 크게 올라갑니다. 꺼져 있으면 추출식 요약으로 대체됩니다.

  ③ 한국어 인식 모델
     앱을 처음 켜면 필요 시 자동으로 내려받습니다. (보통 이미 설치되어 있음)
GUIDE

echo
bold "실행"
echo "  open $(pwd)/ZoomCaption.app"
echo

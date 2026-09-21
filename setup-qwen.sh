#!/bin/bash
# ZoomCaption의 로컬 요약 기능만 추가로 설치합니다.
# 기본 자막 기능에는 필요하지 않습니다.  ./setup-qwen.sh
set -uo pipefail
cd "$(dirname "$0")"

MODEL="qwen3:8b"
MODEL_SIZE="약 5GB"
STARTED_OLLAMA_PID=""

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }

finish() {
  if [ -n "$STARTED_OLLAMA_PID" ]; then
    kill "$STARTED_OLLAMA_PID" >/dev/null 2>&1 || true
  fi
}
trap finish EXIT

bold "ZoomCaption · 로컬 요약 추가 설치"
echo "  Ollama와 $MODEL 모델을 설치합니다 ($MODEL_SIZE 다운로드)."
echo

if [ "$(uname -s)" != "Darwin" ]; then
  bad "이 설치 스크립트는 macOS용입니다."
  exit 1
fi

RAM_GB=$(($(sysctl -n hw.memsize) / 1073741824))
if [ "$RAM_GB" -lt 16 ]; then
  warn "메모리 ${RAM_GB}GB에서는 $MODEL 실행이 느리거나 메모리가 부족할 수 있습니다."
else
  ok "메모리 ${RAM_GB}GB 확인"
fi

if ! command -v ollama >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    bad "Ollama 설치에 Homebrew가 필요합니다."
    echo '  먼저 Homebrew를 설치하세요: https://brew.sh'
    exit 1
  fi

  echo "  → Ollama 설치 중…"
  if brew install ollama; then
    ok "Ollama 설치 완료"
  else
    bad "Ollama를 설치하지 못했습니다. 네트워크와 Homebrew 상태를 확인해 주세요."
    exit 1
  fi
else
  ok "Ollama 이미 설치됨"
fi

if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "  → Ollama를 잠시 시작합니다…"
  nohup ollama serve >/tmp/zoomcaption-ollama-setup.log 2>&1 &
  STARTED_OLLAMA_PID=$!
  READY=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done
  if [ "$READY" != "1" ]; then
    bad "Ollama를 시작하지 못했습니다. 로그: /tmp/zoomcaption-ollama-setup.log"
    exit 1
  fi
fi

if ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qE '^qwen3:8b($|-)'; then
  ok "$MODEL 이미 설치됨"
else
  echo "  → $MODEL 내려받는 중… $MODEL_SIZE, 네트워크에 따라 시간이 걸립니다."
  if ollama pull "$MODEL"; then
    ok "$MODEL 설치 완료"
  else
    bad "$MODEL을 내려받지 못했습니다. 네트워크 연결을 확인한 뒤 다시 실행해 주세요."
    exit 1
  fi
fi

if command -v brew >/dev/null 2>&1 \
  && brew services list 2>/dev/null | grep -q "^ollama *started"; then
  echo "  → Ollama 상시 실행을 끕니다. ZoomCaption이 필요할 때 자동으로 시작합니다."
  brew services stop ollama >/dev/null 2>&1 \
    && ok "Ollama 상시 실행 해제" \
    || warn "상시 실행을 끄지 못했습니다. 요약 기능 사용에는 문제가 없습니다."
fi

echo
bold "설치 완료"
echo "  ZoomCaption의 요약 화면에서 '로컬 모델'을 선택해 사용할 수 있습니다."
echo "  실행: open $(pwd)/ZoomCaption.app"

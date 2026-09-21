#!/bin/bash
# ZoomCaption 관리자 진단 화면 전용 실행기.
#
# 일반 사용 앱과 포트(8766)와 저장 폴더(ZoomCaption-Admin)를 분리한다. 이렇게 하면
# 진단용 WAV 되먹임이나 테스트 세션이 실제 수업 목록에 섞이지 않는다. 관리자 여부는
# URL 파라미터나 브라우저 저장값이 아니라 앱 프로세스의 --admin 인자로 결정되므로,
# 일반 화면에서 주소만 바꿔 관리자 API를 여는 방식은 허용되지 않는다.
set -euo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
APPLICATION_BUNDLE_PATH="$PROJECT_DIRECTORY/ZoomCaption.app"
ADMINISTRATOR_STORAGE_DIRECTORY="$HOME/Documents/ZoomCaption-Admin"

if [[ ! -d "$APPLICATION_BUNDLE_PATH" ]]; then
  echo "ZoomCaption.app을 찾지 못했습니다. 먼저 ./build.sh를 실행해 주세요."
  read -r -p "Enter 키를 누르면 닫힙니다."
  exit 1
fi

# --dir는 관리자 모드에서만 허용된다. 폴더를 먼저 만들면 앱이 첫 진단 세션을
# 시작할 때 경로 권한이나 오타 때문에 실패하는 일을 미리 피할 수 있다.
mkdir -p "$ADMINISTRATOR_STORAGE_DIRECTORY"

echo "ZoomCaption 관리자 모드를 엽니다."
echo "  주소: http://127.0.0.1:8766"
echo "  진단 저장 위치: $ADMINISTRATOR_STORAGE_DIRECTORY"

open -n "$APPLICATION_BUNDLE_PATH" --args \
  --admin \
  --port 8766 \
  --dir "$ADMINISTRATOR_STORAGE_DIRECTORY"

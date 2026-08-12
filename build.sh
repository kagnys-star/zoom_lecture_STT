#!/bin/bash
# ZoomCaption 빌드 스크립트
# SPM으로 실행 파일을 만든 뒤 .app 번들로 감싸고 서명한다.
# 번들로 감싸야 macOS가 "화면 및 시스템 오디오 기록" 권한을 이 앱에 귀속시킬 수 있다.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ZoomCaption"
BUNDLE_ID="com.local.zoomcaption"
APP="$APP_NAME.app"

echo "▸ 컴파일 중…"
swift build -c release --disable-sandbox

BIN=$(swift build -c release --show-bin-path)/$APP_NAME

echo "▸ 앱 번들 구성 중…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>           <string>ZoomCaption</string>
  <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>1.0</string>
  <key>CFBundleVersion</key>               <string>1</string>
  <key>LSMinimumSystemVersion</key>        <string>26.0</string>
  <key>LSUIElement</key>                   <true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>수업 오디오를 자막으로 옮기기 위해 시스템 오디오를 읽습니다. 소리는 기기 밖으로 나가지 않습니다.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>내 질문을 별도 트랙으로 기록하기 위해 마이크를 사용합니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>수업 오디오를 기기 안에서 텍스트로 변환합니다.</string>
</dict>
</plist>
PLIST

echo "▸ 서명 중…"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/  /'

echo
echo "✅ 완료: $(pwd)/$APP"
echo "   실행:  open $(pwd)/$APP"

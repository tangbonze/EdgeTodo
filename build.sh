#!/bin/bash
# 构建「侧边待办」.app —— 只需命令行工具（Xcode CLT），无需 Xcode 工程
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="EdgeTodo"
APP="dist/${APP_NAME}.app"
BUNDLE_ID="com.tangbonze.edgetodo"

echo "==> 清理"
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift"
set +e
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework SwiftUI \
  -framework EventKit \
  -framework Carbon \
  -framework Speech \
  -framework AVFoundation \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME" 2> build/compile.log
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
  echo "-- 编译错误 --"
  grep -E "error:" build/compile.log || cat build/compile.log
  exit 1
fi
echo "    ok（警告 $(grep -c 'warning:' build/compile.log || true) 条，已忽略）"

echo "==> 组装 bundle"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

echo "==> 临时签名（ad-hoc）"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | tail -2

echo "==> 完成: $APP"
du -sh "$APP"

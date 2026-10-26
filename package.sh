#!/bin/bash
# 把 dist/EdgeTodo.app 打成 DMG —— 说明文件见 packaging/dmg-readme.txt（中英双语）
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP="dist/EdgeTodo.app"
DMG="EdgeTodo-${VERSION}-arm64.dmg"

if [ ! -d "$APP" ]; then
  echo "先跑 ./build.sh 生成 $APP" >&2
  exit 1
fi

echo "==> 打包 $DMG"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp -R "$APP" "$TMP/"
ln -s /Applications "$TMP/Applications"
cp packaging/dmg-readme.txt "$TMP/Read Me.txt"

rm -f "$DMG"
hdiutil create -volname "EdgeTodo" -srcfolder "$TMP" -ov -format UDZO "$DMG" >/dev/null

echo "==> 校验"
hdiutil verify "$DMG" 2>&1 | tail -1
echo "==> SHA256"
shasum -a 256 "$DMG" | awk '{print "  " $1}'
du -h "$DMG" | awk '{print "  大小 " $1}'

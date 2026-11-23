#!/bin/bash
# 서명 없는 설치 파일을 만든다: build/Maczip.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

STAGE=build/dmg-staging
DMG=build/Maczip.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Maczip.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "packaging/처음-여는-방법.txt" "$STAGE/"

hdiutil create -volname Maczip -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "만든 설치 파일: $DMG ($(du -h "$DMG" | cut -f1))"

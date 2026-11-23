#!/bin/bash
# 서명 없는 설치 파일을 만든다: build/Maczip.dmg
# dmg를 열었을 때 나타나는 디스크 아이콘도 병아리 아이콘(packaging/AppIcon.icns)으로 지정한다.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

STAGE=build/dmg-staging
RW=build/Maczip-rw.dmg
MOUNT=build/dmg-mount
DMG=build/Maczip.dmg
rm -rf "$STAGE" "$RW" "$DMG" "$MOUNT"
mkdir -p "$STAGE" "$MOUNT"
cp -R build/Maczip.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "packaging/처음-여는-방법.txt" "$STAGE/"
cp packaging/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# 1) 쓰기 가능한 이미지로 만든 뒤 마운트해서 디스크에 '사용자 지정 아이콘' 표시를 켠다.
hdiutil create -volname Maczip -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
hdiutil attach "$RW" -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null

# 2) 배포용 압축 이미지로 변환한다.
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW" "$MOUNT"
echo "만든 설치 파일: $DMG ($(du -h "$DMG" | cut -f1))"

#!/bin/bash
# 앱 아이콘을 다시 그려 packaging/AppIcon.icns 를 만든다.
# 아이콘 모양을 바꾸려면 scripts/icon/AppIcon.swift 를 고친 뒤 이 스크립트를 실행한다.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O scripts/icon/AppIcon.swift -o "$WORK/appicon"
"$WORK/appicon" "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o packaging/AppIcon.icns
cp "$WORK/icon-1024.png" packaging/AppIcon-1024.png
echo "만든 아이콘: packaging/AppIcon.icns"

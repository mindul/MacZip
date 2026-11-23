#!/bin/bash
# Maczip.app 번들을 만든다: build/Maczip.app
set -euo pipefail
cd "$(dirname "$0")/.."

# Apple Silicon과 Intel을 각각 빌드해 하나의 유니버설 바이너리로 합친다.
# (Xcode 없이 Command Line Tools만으로 가능: --arch 대신 --triple 사용)
BINS=()
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx14.0"
    swift build -c release --triple "$TRIPLE" --product MaczipApp
    BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/MaczipApp")
done
mkdir -p build
BIN=build/MaczipApp-universal
lipo -create "${BINS[@]}" -output "$BIN"

APP=build/Maczip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Maczip"
cp packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Apple 개발자 계정이 없으므로 ad-hoc 서명만 한다(Apple Silicon 실행 최소 조건).
codesign --force --deep -s - "$APP"

echo "만든 앱: $APP"
echo "아키텍처: $(lipo -archs "$APP/Contents/MacOS/Maczip")"

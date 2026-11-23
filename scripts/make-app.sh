#!/bin/bash
# 맥집 앱 번들을 만든다: build/맥집.app (실행 파일 이름은 MacZip)
set -euo pipefail
cd "$(dirname "$0")/.."

# Apple Silicon과 Intel을 각각 빌드해 하나의 유니버설 바이너리로 합친다.
# (Xcode 없이 Command Line Tools만으로 가능: --arch 대신 --triple 사용)
BINS=()
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx14.0"
    swift build -c release --triple "$TRIPLE" --product MacZipApp
    BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/MacZipApp")
done
mkdir -p build
BIN=build/MacZipApp-universal
lipo -create "${BINS[@]}" -output "$BIN"

APP="build/맥집.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacZip"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 실제 앱 코드로 사용자 흐름을 따라가 보는 자체 점검(크래시 회귀 방지). 실패하면 여기서 멈춘다.
for ARCH in arm64 x86_64; do
    if ! MACZIP_SELFTEST=1 arch "-$ARCH" "$APP/Contents/MacOS/MacZip"; then
        echo "자체 점검 실패($ARCH): 앱을 배포하지 마세요." >&2
        exit 1
    fi
done

# Apple 개발자 계정이 없으므로 ad-hoc 서명만 한다(Apple Silicon 실행 최소 조건).
codesign --force --deep -s - "$APP"

echo "만든 앱: $APP"
echo "아키텍처: $(lipo -archs "$APP/Contents/MacOS/MacZip")"

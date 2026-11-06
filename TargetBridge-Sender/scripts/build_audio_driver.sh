#!/bin/zsh
# Builds TargetBridgeAudio.driver into <repo>/build. Needs Xcode tools and cmake.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DRIVER_SRC="$ROOT/TargetBridgeAudioDriver"
WORK_DIR="$ROOT/.build/AudioDriver"
ASPL_SRC="$WORK_DIR/libASPL"
ASPL_PREFIX="$WORK_DIR/prefix"
ASPL_TAG="v3.1.2"
MIN_MACOS="14.0"
DEST="$REPO_ROOT/build/TargetBridgeAudio.driver"
IDENTITY="${TARGETBRIDGE_CODESIGN_IDENTITY:--}"

mkdir -p "$WORK_DIR" "$REPO_ROOT/build"

if [[ ! -d "$ASPL_SRC" ]]; then
  git clone --depth 1 --branch "$ASPL_TAG" https://github.com/gavv/libASPL "$ASPL_SRC"
fi

cmake -S "$ASPL_SRC" -B "$WORK_DIR/libASPL-build" -Wno-dev \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$ASPL_PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS"
cmake --build "$WORK_DIR/libASPL-build" --parallel
cmake --install "$WORK_DIR/libASPL-build"

ASPL_LIB="$(find "$ASPL_PREFIX" -name 'libASPL.a' | head -1)"
[[ -n "$ASPL_LIB" ]] || { echo "libASPL.a not found" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
cp "$DRIVER_SRC/Info.plist" "$DEST/Contents/Info.plist"
mkdir -p "$DEST/Contents/Resources/libASPL"
cp "$ASPL_SRC"/LICENSE* "$DEST/Contents/Resources/libASPL/"

clang++ -std=c++17 -O2 -fPIC -bundle \
  -arch arm64 -arch x86_64 -mmacosx-version-min="$MIN_MACOS" \
  -I "$ASPL_PREFIX/include" \
  "$DRIVER_SRC/Driver.cpp" "$ASPL_LIB" \
  -framework CoreFoundation \
  -o "$DEST/Contents/MacOS/TargetBridgeAudio"

codesign --force --sign "$IDENTITY" "$DEST"
codesign --verify --strict "$DEST"
echo "Built $DEST"

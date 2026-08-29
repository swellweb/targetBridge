#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
APP_DIR="${BUILD_DIR}/TargetBridge Receiver.app"
BIN_NAME="TargetBridgeReceiver"
APP_NAME="TargetBridge Receiver"
APP_VERSION="3.5.1"
STAMP="$(date +%Y%m%d%H%M%S)"
ARCH="$(uname -m)"
ICONSET_DIR="$(mktemp -d)"
ICON_FILE="${ROOT}/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
ICNS_PATH="${APP_DIR}/Contents/Resources/TargetBridgeReceiver.icns"

cd "$ROOT/TBReceiverC"
make clean
make APP_VERSION="${APP_VERSION}" APP_BUILD="$STAMP"

mkdir -p "$BUILD_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Resources/Languages"

cp "$ROOT/TBReceiverC/tbreceiver" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$REPO_ROOT/TargetBridge-Shared/Languages/"*.json "$APP_DIR/Contents/Resources/Languages/"

# Bundle dylib dependencies (ffmpeg and SDL) inside the .app.
# Some Homebrew installations provide sdl2-compat, which loads SDL3 at runtime
# through dlopen. dylibbundler cannot discover that dependency, while genuine
# SDL2 does not need SDL3 at all. Inspect the bundled SDL2 artifact instead of
# assuming which formula Homebrew resolved on the build Mac.
mkdir -p "$APP_DIR/Contents/Frameworks"
if ! command -v dylibbundler &>/dev/null; then
  echo "Installing dylibbundler..."
  brew install dylibbundler
fi
dylibbundler -od -b \
  -x "$APP_DIR/Contents/MacOS/$BIN_NAME" \
  -d "$APP_DIR/Contents/Frameworks/" \
  -p @executable_path/../Frameworks/ \
  >/dev/null 2>&1

SDL2_IN_APP="$(find "$APP_DIR/Contents/Frameworks" -type f -name 'libSDL2*.dylib' -print -quit)"
if [[ -n "$SDL2_IN_APP" ]] && strings -a "$SDL2_IN_APP" | grep -q 'libSDL3'; then
  SDL3_PREFIX="$(brew --prefix sdl3 2>/dev/null || true)"
  SDL3_DYLIB="${SDL3_PREFIX}/lib/libSDL3.dylib"
  if [[ -z "$SDL3_PREFIX" || ! -f "$SDL3_DYLIB" ]]; then
    echo "SDL3 runtime library is required by bundled sdl2-compat but was not found" >&2
    exit 1
  fi
  cp -L "$SDL3_DYLIB" "$APP_DIR/Contents/Frameworks/libSDL3.dylib"
  install_name_tool \
    -id "@executable_path/../Frameworks/libSDL3.dylib" \
    "$APP_DIR/Contents/Frameworks/libSDL3.dylib"
else
  echo "Bundled SDL2 is native; SDL3 runtime is not required."
fi

if [[ -f "$ICON_FILE" ]]; then
  mkdir -p "${ICONSET_DIR}/TargetBridgeReceiver.iconset"
  sips -z 16 16     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_512x512.png" >/dev/null
  cp "$ICON_FILE" "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_512x512@2x.png"
  iconutil -c icns "${ICONSET_DIR}/TargetBridgeReceiver.iconset" -o "$ICNS_PATH" >/dev/null 2>&1 || true
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.targetbridge.receiver</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>TargetBridgeReceiver</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>$STAMP</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
# Sign each bundled dylib first, then the app
find "$APP_DIR/Contents/Frameworks" -name "*.dylib" | while read dylib; do
  codesign --force --sign - "$dylib" >/dev/null 2>&1 || true
done
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

# A released bundle must never depend on the Homebrew installation used to
# compile it. Check the executable and every bundled dynamic library after
# dylibbundler and the optional SDL3 copy have completed.
MACHO_FILES=(
  "$APP_DIR/Contents/MacOS/$BIN_NAME"
  "$APP_DIR/Contents/Frameworks/"*.dylib(N)
)
EXTERNAL_HOMEBREW_REFS="$(
  otool -L "${MACHO_FILES[@]}" 2>/dev/null |
    awk '$1 ~ /^\/(usr\/local|opt\/homebrew)\// { print }'
)"
if [[ -n "$EXTERNAL_HOMEBREW_REFS" ]]; then
  echo "Receiver bundle still contains external Homebrew references:" >&2
  echo "$EXTERNAL_HOMEBREW_REFS" >&2
  exit 1
fi

xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
rm -rf "$ICONSET_DIR"

echo "${APP_NAME} built: $APP_DIR"
echo "Version: ${APP_VERSION} ($STAMP)"
echo "Build architecture: $ARCH"

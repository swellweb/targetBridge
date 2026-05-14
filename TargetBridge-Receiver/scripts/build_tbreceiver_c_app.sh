#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${HOME}/Desktop/TargetBridge Receiver.app"
BIN_NAME="TargetBridgeReceiver"
APP_NAME="TargetBridge Receiver"
APP_VERSION="0.1.0-rc1"
STAMP="$(date +%Y%m%d%H%M%S)"
ARCH="$(uname -m)"
ICONSET_DIR="$(mktemp -d)"
ICON_FILE="${ROOT}/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
ICNS_PATH="${APP_DIR}/Contents/Resources/TargetBridgeReceiver.icns"

cd "$ROOT/TBReceiverC"
make clean
make APP_VERSION="${APP_VERSION}" APP_BUILD="$STAMP"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT/TBReceiverC/tbreceiver" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"

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
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
rm -rf "$ICONSET_DIR"

echo "${APP_NAME} built: $APP_DIR"
echo "Versione: ${APP_VERSION} ($STAMP)"
echo "Architettura build: $ARCH"

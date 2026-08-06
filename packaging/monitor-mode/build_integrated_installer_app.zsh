#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_DIR="${SCRIPT_DIR}/installer-app"
RECEIVER_ARCHIVE="${1:?pass Receiver zip as first argument}"
SENDER_ARCHIVE="${2:?pass Sender zip as second argument}"
OUTPUT_DIR="${3:-${SCRIPT_DIR}/build}"
APP="${OUTPUT_DIR}/TargetBridge Installer.app"
CONTENTS="${APP}/Contents"
RESOURCES="${CONTENTS}/Resources"
MODULE_CACHE="$(/usr/bin/mktemp -d /private/tmp/targetbridge-installer-module-cache.XXXXXX)"
BUILD_TEMP="$(/usr/bin/mktemp -d /private/tmp/targetbridge-installer-build.XXXXXX)"
VERSION="1.0.16"
BUILD="$(/bin/date +%Y%m%d%H%M%S)"

finish() {
    /bin/rm -R "${MODULE_CACHE}" "${BUILD_TEMP}" >/dev/null 2>&1 || true
}
trap finish EXIT

[[ -r "${RECEIVER_ARCHIVE}" && -r "${SENDER_ARCHIVE}" ]] || {
    print -u2 -- "Missing TargetBridge payload archives"
    exit 2
}

/bin/mkdir -p "${OUTPUT_DIR}"
[[ ! -e "${APP}" ]] || /bin/rm -R "${APP}"
/bin/mkdir -p "${CONTENTS}/MacOS" "${RESOURCES}/Payloads" "${RESOURCES}/Support"

SWIFT_SOURCE="${SOURCE_DIR}/TargetBridgeInstaller.swift"
xcrun swiftc -target arm64-apple-macos13.0 \
    -parse-as-library \
    -module-cache-path "${MODULE_CACHE}" \
    "${SWIFT_SOURCE}" -o "${BUILD_TEMP}/installer-arm64"
xcrun swiftc -target x86_64-apple-macos13.0 \
    -parse-as-library \
    -module-cache-path "${MODULE_CACHE}" \
    "${SWIFT_SOURCE}" -o "${BUILD_TEMP}/installer-x86_64"
/usr/bin/lipo -create \
    "${BUILD_TEMP}/installer-arm64" \
    "${BUILD_TEMP}/installer-x86_64" \
    -output "${CONTENTS}/MacOS/TargetBridgeInstaller"
/bin/chmod 755 "${CONTENTS}/MacOS/TargetBridgeInstaller"

/bin/cp "${RECEIVER_ARCHIVE}" "${RESOURCES}/Payloads/TargetBridge-Receiver.zip"
/bin/cp "${SENDER_ARCHIVE}" "${RESOURCES}/Payloads/TargetBridge-Sender.zip"
/bin/cp "${SOURCE_DIR}/install-targetbridge.zsh" "${RESOURCES}/Support/install-targetbridge.zsh"
/bin/cp "${SCRIPT_DIR}/targetbridge-restart-sender" "${RESOURCES}/Support/targetbridge-restart-sender"
/bin/cp "${SOURCE_DIR}/com.targetbridge.sender.autostart.template.plist" "${RESOURCES}/Support/com.targetbridge.sender.autostart.template.plist"
/bin/chmod 700 "${RESOURCES}/Support/install-targetbridge.zsh" "${RESOURCES}/Support/targetbridge-restart-sender"

(
    cd "${RESOURCES}"
    /usr/bin/shasum -a 256 \
        "Payloads/TargetBridge-Receiver.zip" \
        "Payloads/TargetBridge-Sender.zip" \
        "Support/targetbridge-restart-sender" \
        "Support/com.targetbridge.sender.autostart.template.plist" \
        > "manifest.sha256"
)

ICON_SOURCE_ICNS="${SCRIPT_DIR:h:h}/build/TargetBridge.app/Contents/Resources/AppIcon.icns"
ICON_SOURCE="${SCRIPT_DIR:h:h}/TargetBridge-Receiver/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
if [[ -r "${ICON_SOURCE_ICNS}" ]]; then
    /bin/cp "${ICON_SOURCE_ICNS}" "${RESOURCES}/TargetBridgeInstaller.icns"
elif [[ -r "${ICON_SOURCE}" ]]; then
    ICONSET="${BUILD_TEMP}/TargetBridgeInstaller.iconset"
    /bin/mkdir -p "${ICONSET}"
    /usr/bin/sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET}/icon_16x16.png" >/dev/null
    /usr/bin/sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
    /usr/bin/sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET}/icon_32x32.png" >/dev/null
    /usr/bin/sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
    /usr/bin/sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET}/icon_128x128.png" >/dev/null
    /usr/bin/sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
    /usr/bin/sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET}/icon_256x256.png" >/dev/null
    /usr/bin/sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
    /usr/bin/sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET}/icon_512x512.png" >/dev/null
    /usr/bin/sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
    /usr/bin/iconutil -c icns "${ICONSET}" -o "${RESOURCES}/TargetBridgeInstaller.icns" >/dev/null 2>&1 || true
fi

/bin/cat > "${CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>it</string>
<key>CFBundleDisplayName</key><string>TargetBridge Installer</string>
<key>CFBundleExecutable</key><string>TargetBridgeInstaller</string>
<key>CFBundleIdentifier</key><string>com.targetbridge.installer</string>
<key>CFBundleIconFile</key><string>TargetBridgeInstaller</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>TargetBridge Installer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
/usr/bin/printf 'APPL????' > "${CONTENTS}/PkgInfo"
/usr/bin/codesign --force --deep --sign - \
    --identifier com.targetbridge.installer \
    --requirements '=designated => identifier "com.targetbridge.installer"' \
    "${APP}"
/usr/bin/xattr -cr "${APP}" >/dev/null 2>&1 || true

print -- "BUILT:${APP}"
print -- "ARCHITECTURES:$(/usr/bin/lipo -archs "${CONTENTS}/MacOS/TargetBridgeInstaller")"

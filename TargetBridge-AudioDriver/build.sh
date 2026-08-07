#!/bin/bash
# Builds TargetBridge.driver — a CFPlugIn bundle loaded by coreaudiod.
# libASPL is compiled directly from vendor/ so cmake is not required.
set -euo pipefail
cd "$(dirname "$0")"

NAME=TargetBridge
BUNDLE="build/$NAME.driver"
LIB=vendor/libASPL

rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS"

# Stamp the bundle with a hash of what it was built from, so the app can tell an
# installed driver apart from the one it ships and offer to update it. A running
# driver whose code no longer matches the app is invisible otherwise — it looks
# exactly like a change that did nothing, which cost us a day of debugging once.
BUILD_ID=$(cat Driver.cpp build.sh | shasum -a 256 | cut -c1-12)

CXXFLAGS=(-std=c++17 -O2 -fPIC -arch arm64 -arch x86_64
          -mmacosx-version-min=11.0
          -I"$LIB/include" -I"$LIB/src" -Wno-unused-parameter -Wno-reorder-init-list)

echo "### compiling ($(find "$LIB/src" -name '*.cpp' | wc -l | tr -d ' ') libASPL sources + driver)"
clang++ "${CXXFLAGS[@]}" -bundle \
  -o "$BUNDLE/Contents/MacOS/$NAME" \
  Driver.cpp $(find "$LIB/src" -name '*.cpp') \
  -framework CoreAudio -framework CoreFoundation

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.targetbridge.audiodriver</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$BUILD_ID</string>
    <key>CFPlugInFactories</key>
    <dict>
        <!-- Any fresh UUID; coreaudiod maps it to our factory symbol. -->
        <key>C4E4A1B2-7F3D-4A6E-9B21-8D5F0A3C6E10</key>
        <string>TargetBridgeAudioDriverFactory</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <!-- kAudioServerPlugInTypeUUID: identifies this as an audio server plug-in. -->
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array><string>C4E4A1B2-7F3D-4A6E-9B21-8D5F0A3C6E10</string></array>
    </dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || echo "  (ad-hoc signing failed — may not load)"
echo "### built $BUNDLE"
lipo -archs "$BUNDLE/Contents/MacOS/$NAME"

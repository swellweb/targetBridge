#!/bin/bash
# build_x86_bundle.sh — build a self-contained x86_64 receiver .app.
#
# WHY THIS EXISTS
#
# The receiver runs on Intel Macs (the reference target is a 2020 Retina 5K
# iMac), but Homebrew no longer ships x86_64 bottles for current ffmpeg or SDL2.
# So the receiver cannot be built on the Intel machine with `brew install`, and
# it cannot be cross-compiled on an Apple Silicon Mac against Homebrew's arm64
# libraries either. This script builds the dependencies it needs, for the right
# architecture, and produces a bundle that runs on a machine with nothing
# installed on it.
#
# IT IS SELF-HEALING ON PURPOSE
#
# A previous version of this toolchain lived in a temporary directory and was
# deleted by the system's /tmp cleanup, which turned a routine build into an
# afternoon of archaeology. Everything below is therefore idempotent: it checks
# what is already staged, fetches or builds only what is missing, and keeps the
# result under $HOME where nothing sweeps it away. Deleting the cache costs one
# command, not a recipe hunt.
#
#   ./build_x86_bundle.sh              build the bundle
#   ./build_x86_bundle.sh --clean      discard the staged toolchain first
#
# Output: dist/TBReceiver.app, ad-hoc signed, no dependencies.

set -euo pipefail

FFMPEG_VERSION=8.1.2
SDL2_VERSION=2.32.10
MIN_MACOS=11.0

HERE="$(cd "$(dirname "$0")" && pwd)"
RECEIVER="$(cd "$HERE/.." && pwd)"
SRC="$RECEIVER/TBReceiverC/src"
CODEC="$(cd "$RECEIVER/../TargetBridge-Shared/codec" && pwd)"
LANGUAGES="$(cd "$RECEIVER/../TargetBridge-Shared/Languages" && pwd)"

# Under $HOME, not /tmp. This is the whole point.
CACHE="${TB_X86_CACHE:-$HOME/Library/Caches/TargetBridge/x86-toolchain}"
STAGE="$CACHE/stage"
OUT="$HERE/dist"
APP="$OUT/TBReceiver.app"

if [ "${1:-}" = "--clean" ]; then
    echo "==> discarding $CACHE"
    rm -rf "$CACHE"
fi

mkdir -p "$STAGE"

# ---------------------------------------------------------------- SDL2
# Apple-style framework from the official DMG, which is universal — no build
# needed, and it is the only SDL2 that ships an x86_64 slice today.
if [ ! -f "$STAGE/SDL2.framework/Versions/A/SDL2" ]; then
    echo "==> fetching SDL2 $SDL2_VERSION"
    rm -rf "$STAGE/SDL2.framework"
    dmg="$CACHE/SDL2-$SDL2_VERSION.dmg"
    [ -f "$dmg" ] || curl -sSL --max-time 300 -o "$dmg" \
        "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VERSION/SDL2-$SDL2_VERSION.dmg"
    mnt="$CACHE/mnt"
    mkdir -p "$mnt"
    hdiutil attach -nobrowse -quiet "$dmg" -mountpoint "$mnt"
    ditto "$mnt/SDL2.framework" "$STAGE/SDL2.framework"
    hdiutil detach "$mnt" -quiet
    rmdir "$mnt"
else
    echo "==> SDL2 already staged"
fi

# ---------------------------------------------------------------- ffmpeg
# Built from source for x86_64, and deliberately minimal: the receiver only ever
# decodes HEVC or H.264, and in raw/DPCM passthrough it does not decode at all.
# Configuring everything off and those two on turns a very long build into a
# short one.
if [ ! -f "$STAGE/lib/libavcodec.dylib" ]; then
    echo "==> building ffmpeg $FFMPEG_VERSION for x86_64 (a few minutes)"
    tar="$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz"
    [ -f "$tar" ] || curl -sSL --max-time 600 -o "$tar" \
        "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    rm -rf "$CACHE/ffmpeg-$FFMPEG_VERSION"
    tar xf "$tar" -C "$CACHE"
    (
        cd "$CACHE/ffmpeg-$FFMPEG_VERSION"
        ./configure \
            --prefix="$STAGE" \
            --enable-cross-compile --arch=x86_64 --cpu=x86-64 --target-os=darwin \
            --cc="clang -arch x86_64 -mmacosx-version-min=$MIN_MACOS" \
            --enable-shared --disable-static \
            --disable-programs --disable-doc \
            --disable-everything \
            --enable-decoder=hevc,h264 \
            --enable-hwaccel=hevc_videotoolbox,h264_videotoolbox \
            --enable-videotoolbox \
            --disable-network --disable-autodetect > "$CACHE/configure.log" 2>&1
        make -j"$(sysctl -n hw.ncpu)" install > "$CACHE/build.log" 2>&1
    )
else
    echo "==> ffmpeg already staged"
fi

for lib in libavcodec libavutil libswscale; do
    got="$(lipo -archs "$STAGE/lib/$lib.dylib")"
    [ "$got" = "x86_64" ] || { echo "!! $lib is '$got', expected x86_64"; exit 1; }
done

# ---------------------------------------------------------------- compile
echo "==> compiling receiver"
OBJ="$CACHE/obj"
rm -rf "$OBJ"; mkdir -p "$OBJ"

VERSION="$(git -C "$RECEIVER" describe --tags --always 2>/dev/null || echo dev)"

CFLAGS=(
    -arch x86_64 -mmacosx-version-min=$MIN_MACOS
    -O2 -Wall -Wextra -Wno-unused-parameter -std=c11
    -I"$SRC" -I"$CODEC"
    -I"$STAGE/include"
    -F"$STAGE" -I"$STAGE/SDL2.framework/Headers"
    -DTB_RECEIVER_VERSION="\"$VERSION\"" -DTB_RECEIVER_BUILD="\"x86_64\""
    # No TB_LANGUAGE_SOURCE_DIR: a shipped bundle must read its own Resources,
    # and pointing at a build-machine path would silently work here and fail
    # everywhere else.
)

# Every translation unit the Makefile builds. Kept in step with it deliberately:
# a source file present in one build and not the other has broken CI in this
# project more than once.
SOURCES=(
    "$SRC/main.c" "$SRC/net.c" "$SRC/decoder.c" "$SRC/display.c" "$SRC/tb_i18n.c"
    "$SRC/tb_logship.c"
    "$CODEC/tb_dpcm.c"
    "$SRC/tb_gesture_bridge.m" "$SRC/tb_display_tweaks.m"
    "$SRC/tb_mic_capture.m" "$SRC/tb_metal_plane.m" "$SRC/tb_health.m"
)
for s in "${SOURCES[@]}"; do
    [ -f "$s" ] || { echo "!! missing source $s"; exit 1; }
done

objs=()
for s in "${SOURCES[@]}"; do
    o="$OBJ/$(basename "${s%.*}").o"
    # Written as two branches rather than an "extra flags" array: macOS ships
    # bash 3.2, where expanding an empty array trips `set -u`.
    case "$s" in
        *.m) clang "${CFLAGS[@]}" -fobjc-arc -c "$s" -o "$o" ;;
        *)   clang "${CFLAGS[@]}" -c "$s" -o "$o" ;;
    esac
    objs+=("$o")
done

clang -arch x86_64 -mmacosx-version-min=$MIN_MACOS -o "$OBJ/tbreceiver" "${objs[@]}" \
    -L"$STAGE/lib" -lavcodec -lavutil -lswscale \
    -F"$STAGE" -framework SDL2 \
    -rpath @loader_path/../Frameworks \
    -framework ApplicationServices -framework AppKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreText -framework VideoToolbox \
    -framework CoreMedia -framework CoreVideo -framework IOSurface \
    -framework CoreServices -framework CoreAudio -framework AVFoundation \
    -framework Metal -framework QuartzCore -framework IOKit

# ---------------------------------------------------------------- bundle
echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$OBJ/tbreceiver" "$APP/Contents/MacOS/TBReceiver"
ditto "$STAGE/SDL2.framework" "$APP/Contents/Frameworks/SDL2.framework"
# Resolve the symlinks: a bundle carries the real file, not a link into a
# staging directory that will not exist on the target machine.
for lib in libavcodec libavutil libswscale; do
    real="$(cd "$STAGE/lib" && readlink "$lib.dylib" || echo "$lib.dylib")"
    cp "$STAGE/lib/$real" "$APP/Contents/Frameworks/$lib.dylib"
done

# The receiver reads its translations from Resources/Languages at runtime.
ditto "$LANGUAGES" "$APP/Contents/Resources/Languages"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>TBReceiver</string>
	<key>CFBundleIdentifier</key><string>com.targetbridge.receiver</string>
	<key>CFBundleName</key><string>TargetBridge Receiver</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>TargetBridge forwards this Mac's microphone to the sending Mac.</string>
	<key>NSCameraUsageDescription</key>
	<string>TargetBridge forwards this Mac's camera to the sending Mac.</string>
</dict>
</plist>
PLIST

# Point the executable at the copies inside the bundle rather than at the
# staging directory it was linked against.
BIN="$APP/Contents/MacOS/TBReceiver"
for lib in libavcodec libavutil libswscale; do
    old="$(otool -L "$BIN" | awk -v l="$lib" '$1 ~ l {print $1; exit}')"
    [ -n "$old" ] && install_name_tool -change "$old" "@loader_path/../Frameworks/$lib.dylib" "$BIN"
done
# The bundled dylibs reference each other too.
for lib in libavcodec libswscale; do
    for dep in libavutil libswscale; do
        old="$(otool -L "$APP/Contents/Frameworks/$lib.dylib" | awk -v l="$dep" '$1 ~ l && $1 !~ /^\/usr/ {print $1; exit}')"
        [ -n "$old" ] && install_name_tool -change "$old" "@loader_path/$dep.dylib" \
            "$APP/Contents/Frameworks/$lib.dylib" 2>/dev/null || true
    done
    install_name_tool -id "@loader_path/$lib.dylib" "$APP/Contents/Frameworks/$lib.dylib" 2>/dev/null || true
done
install_name_tool -id "@loader_path/libavutil.dylib" "$APP/Contents/Frameworks/libavutil.dylib" 2>/dev/null || true

codesign --force --deep --sign - "$APP" 2>/dev/null

echo
echo "==> $APP"
lipo -archs "$BIN"
echo "    remaining non-system links (should be none):"
otool -L "$BIN" | grep -vE "/usr/lib|/System|@loader_path|@rpath|:$" || echo "    none"

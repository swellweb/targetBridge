#!/bin/zsh
# Build the Receiver's FFmpeg and SDL2 runtimes from pinned sources for an older
# macOS than the build machine runs.
#
# Homebrew bottles target the runner's own macOS, so a Receiver bundled from
# them needs macOS 14+ (Intel) or 15+ (Apple Silicon). The 2014-2017 5K iMacs
# the Receiver is meant for stop at Big Sur, Monterey, or Ventura (#167, #223).
#
# Usage: build_receiver_runtime.sh PREFIX
#   then: PKG_CONFIG_PATH=PREFIX/lib/pkgconfig ./build_tbreceiver_c_app.sh
# Honours MACOSX_DEPLOYMENT_TARGET (default 11.0). Needs cmake and pkgconf;
# Intel also needs nasm. Re-running with an existing PREFIX is a no-op.
set -euo pipefail

PREFIX="${1:?Usage: build_receiver_runtime.sh PREFIX}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

FFMPEG_VERSION=7.1.1
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
SDL2_VERSION=2.30.9
SDL2_SHA256=24b574f71c87a763f50704bbb630cbe38298d544a1f890f099a4696b1d6beba4

STAMP="$PREFIX/.runtime-ffmpeg${FFMPEG_VERSION}-sdl${SDL2_VERSION}-macos${MACOSX_DEPLOYMENT_TARGET}"
if [[ -f "$STAMP" ]]; then
  print -- "Receiver runtime already built: $PREFIX"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
JOBS="$(sysctl -n hw.ncpu)"

fetch() {  # url sha256 dest
  curl -fsSL --retry 3 -o "$3" "$1"
  print -- "$2  $3" | shasum -a 256 -c - >/dev/null || { print -u2 "Checksum mismatch: $1"; exit 1; }
}

# FFmpeg: only what decoder.c uses (H.264/HEVC decode, VideoToolbox hwaccel
# plus software fallback, swscale). --disable-autodetect keeps optional system
# libraries (iconv, zlib, SecureTransport, ...) out of the bundle.
fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" "$FFMPEG_SHA256" "$WORK/ffmpeg.tar.xz"
tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
(
  cd "$WORK/ffmpeg-${FFMPEG_VERSION}"
  ./configure --prefix="$PREFIX" \
    --enable-shared --disable-static \
    --disable-programs --disable-doc --disable-network --disable-autodetect \
    --disable-everything \
    --enable-videotoolbox \
    --enable-decoder=h264,hevc \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
    --enable-parser=h264,hevc \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swresample \
    --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
  make -j"$JOBS"
  make install
)

# Genuine SDL2 (not Homebrew's sdl2-compat, which dlopens SDL3 at runtime).
fetch "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" "$SDL2_SHA256" "$WORK/sdl2.tar.gz"
tar -xzf "$WORK/sdl2.tar.gz" -C "$WORK"
cmake -S "$WORK/SDL2-${SDL2_VERSION}" -B "$WORK/sdl2-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
cmake --build "$WORK/sdl2-build" -j "$JOBS"
cmake --install "$WORK/sdl2-build"

touch "$STAMP"
print -- "Receiver runtime built for macOS $MACOSX_DEPLOYMENT_TARGET+: $PREFIX"

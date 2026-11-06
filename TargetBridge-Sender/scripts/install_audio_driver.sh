#!/bin/zsh
# Usage: sudo ./install_audio_driver.sh      install the built driver
#        sudo ./install_audio_driver.sh -u   remove it
# Restarting coreaudiod briefly interrupts all audio on this Mac.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE="$REPO_ROOT/build/TargetBridgeAudio.driver"
TARGET="/Library/Audio/Plug-Ins/HAL/TargetBridgeAudio.driver"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this with sudo." >&2
  exit 1
fi

if [[ "${1:-}" == "-u" ]]; then
  rm -rf "$TARGET"
else
  [[ -d "$SOURCE" ]] || { echo "Build the driver first." >&2; exit 1; }
  mkdir -p "$(dirname "$TARGET")"
  rm -rf "$TARGET"
  ditto "$SOURCE" "$TARGET"
  chown -R root:wheel "$TARGET"
fi

killall coreaudiod
echo "Done."

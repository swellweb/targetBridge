#!/bin/bash
# Installs the driver and restarts the audio server so it is actually loaded.
# Requires admin.
set -e
cd "$(dirname "$0")"
[ -d build/TargetBridge.driver ] || { echo "run build.sh first"; exit 1; }

PLUGIN=/Library/Audio/Plug-Ins/HAL/TargetBridge.driver

# Recent macOS hosts each plug-in in a Core-Audio-Driver-Service.helper, and
# those helpers OUTLIVE a restart of the audio server — the old copy keeps
# running and keeps its sockets, so the freshly installed binary looks like it
# changed nothing.
#
# Find them by which process has OUR binary open, not by process name: every
# audio plug-in on the machine shares that process name, so matching on it would
# restart other vendors' drivers as collateral. This has to happen before the
# file is replaced, while the path still refers to the inode they hold.
holders=$(sudo lsof -t "$PLUGIN/Contents/MacOS/TargetBridge" 2>/dev/null || true)

sudo rm -rf "$PLUGIN"
sudo cp -R build/TargetBridge.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel "$PLUGIN"

if [ -n "$holders" ]; then
  # shellcheck disable=SC2086 # deliberately word-split: one pid per line
  sudo kill $holders 2>/dev/null || true
  echo "cleared $(echo "$holders" | wc -w | tr -d ' ') stale plug-in host(s)"
fi

# The audio server only loads HAL plug-ins at startup. Recent macOS uses
# audiomxd; older releases use coreaudiod. Restart whichever is present, and
# fail loudly if neither is, rather than silently not reloading.
restarted=0
for proc in audiomxd coreaudiod; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    sudo killall "$proc" 2>/dev/null || true
    echo "restarted $proc"
    restarted=1
  fi
done

if [ "$restarted" -eq 0 ]; then
  echo "WARNING: no audio server process found (audiomxd/coreaudiod)."
  echo "         The driver will not load until one restarts — log out or reboot."
  exit 1
fi

echo "installed. Check Audio MIDI Setup for 'TargetBridge'."
echo "Driver logs: log show --last 5m --predicate 'subsystem == \"com.targetbridge.audiodriver\"'"

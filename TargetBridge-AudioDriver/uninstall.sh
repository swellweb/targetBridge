#!/bin/bash
# Removes the driver and restarts the audio server. Run this if audio misbehaves.
set -e
sudo rm -rf /Library/Audio/Plug-Ins/HAL/TargetBridge.driver
for proc in audiomxd coreaudiod; do
  pgrep -x "$proc" >/dev/null 2>&1 && sudo killall "$proc" 2>/dev/null || true
done
echo "removed; audio server restarted"

#!/bin/zsh
set -euo pipefail

PLIST_PATH="${HOME}/Library/LaunchAgents/com.targetbridge.receiver.plist"

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
rm -f "${PLIST_PATH}"

echo "LaunchAgent rimosso: ${PLIST_PATH}"
echo "TargetBridge Receiver non partira' piu' automaticamente al login."

#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-${HOME}/Desktop/TargetBridge Receiver.app}"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.targetbridge.receiver.plist"
LOG_DIR="${HOME}/Library/Logs"
STDOUT_LOG="${LOG_DIR}/TargetBridgeReceiver.launchd.out.log"
STDERR_LOG="${LOG_DIR}/TargetBridgeReceiver.launchd.err.log"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Receiver app non trovata: ${APP_PATH}" >&2
  echo "Builda prima TargetBridge Receiver.app oppure passa il path corretto come primo argomento." >&2
  exit 1
fi

mkdir -p "${PLIST_DIR}" "${LOG_DIR}"

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.targetbridge.receiver</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>${APP_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
    <key>StandardOutPath</key>
    <string>${STDOUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
launchctl enable "gui/$(id -u)/com.targetbridge.receiver" >/dev/null 2>&1 || true

echo "LaunchAgent installato: ${PLIST_PATH}"
echo "TargetBridge Receiver configurato per avviarsi automaticamente al login."
echo "App target: ${APP_PATH}"

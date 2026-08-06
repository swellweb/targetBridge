#!/bin/zsh
set -euo pipefail

TEST_DIR="${0:A:h}"
HELPER="${TEST_DIR:h}/targetbridge-restart-sender"
ROOT="$(/usr/bin/mktemp -d /tmp/targetbridge-helper-test.XXXXXX)"
trap '/bin/rm -rf "${ROOT}"' EXIT

export TB_TARGET_HOME="${ROOT}/home"
export TB_TARGET_UID="501"
export TB_CONSOLE_USER="${USER}"
export TB_SENDER_STATE_DIR="${TB_TARGET_HOME}/Library/Application Support/TargetBridge/Sender"
export TB_SENDER_PLIST="${TB_TARGET_HOME}/Library/LaunchAgents/com.targetbridge.sender.autostart.plist"
export TB_SENDER_EXEC="${ROOT}/TargetBridge"
export TB_LAUNCHCTL_BIN="${TEST_DIR}/mock_launchctl.zsh"
export TB_TEST_LAUNCHCTL_LOG="${ROOT}/launchctl.log"
export TB_TEST_SERVICE_LOADED=1

/bin/mkdir -p "${TB_SENDER_PLIST:h}"
print -- "plist" > "${TB_SENDER_PLIST}"
print -- '#!/bin/zsh' > "${TB_SENDER_EXEC}"
/bin/chmod 700 "${TB_SENDER_EXEC}" "${HELPER}" "${TB_LAUNCHCTL_BIN}"

failures=0
checks=0
check() {
    checks=$((checks + 1))
    if ! eval "$2"; then
        print -u2 -- "FAIL: $1"
        failures=$((failures + 1))
    fi
}

export SSH_ORIGINAL_COMMAND="path thunderbolt"
result="$(${HELPER})"
check "path action succeeds" '[[ "${result}" == *"SENDER_STARTED"* ]]'
check "path is persisted" '[[ "$(<"${TB_SENDER_STATE_DIR}/requested-path")" == "thunderbolt" ]]'
check "enabled marker exists" '[[ -f "${TB_SENDER_STATE_DIR}/enabled" ]]'
check "path change restarts in place" '/usr/bin/grep -q "kickstart -k gui/501/com.targetbridge.sender.autostart" "${TB_TEST_LAUNCHCTL_LOG}"'
check "path change never removes login item" '! /usr/bin/grep -q "bootout" "${TB_TEST_LAUNCHCTL_LOG}"'
check "loaded path change never bootstraps" '! /usr/bin/grep -q "bootstrap" "${TB_TEST_LAUNCHCTL_LOG}"'

: > "${TB_TEST_LAUNCHCTL_LOG}"
result="$(${HELPER})"
check "same path succeeds" '[[ "${result}" == *"SENDER_STARTED"* ]]'
check "same running path does not restart" '! /usr/bin/grep -q "kickstart" "${TB_TEST_LAUNCHCTL_LOG}"'

: > "${TB_TEST_LAUNCHCTL_LOG}"
export SSH_ORIGINAL_COMMAND="input on"
result="$(${HELPER})"
check "input option succeeds" '[[ "${result}" == *"INPUT_SET:receiver"* ]]'
check "input option is persisted" '[[ "$(<"${TB_SENDER_STATE_DIR}/requested-input")" == "receiver" ]]'
check "live input change restarts sender" '/usr/bin/grep -q "kickstart -k gui/501/com.targetbridge.sender.autostart" "${TB_TEST_LAUNCHCTL_LOG}"'

: > "${TB_TEST_LAUNCHCTL_LOG}"
export SSH_ORIGINAL_COMMAND="input on"
result="$(${HELPER})"
check "same input option succeeds" '[[ "${result}" == *"INPUT_SET:receiver"* ]]'
check "same live input option restarts for permission refresh" '/usr/bin/grep -q "kickstart -k gui/501/com.targetbridge.sender.autostart" "${TB_TEST_LAUNCHCTL_LOG}"'

export SSH_ORIGINAL_COMMAND="stop"
result="$(${HELPER})"
check "stop succeeds" '[[ "${result}" == *"SENDER_STOPPED"* ]]'
check "stop removes enabled marker" '[[ ! -e "${TB_SENDER_STATE_DIR}/enabled" ]]'
check "stop keeps login item registered" '! /usr/bin/grep -q "bootout" "${TB_TEST_LAUNCHCTL_LOG}"'

: > "${TB_TEST_LAUNCHCTL_LOG}"
export SSH_ORIGINAL_COMMAND="input off"
result="$(${HELPER})"
check "stopped input option succeeds" '[[ "${result}" == "INPUT_SET:off" ]]'
check "stopped input option is persisted" '[[ "$(<"${TB_SENDER_STATE_DIR}/requested-input")" == "off" ]]'
check "stopped input option does not reconnect" '! /usr/bin/grep -q "kickstart" "${TB_TEST_LAUNCHCTL_LOG}"'

: > "${TB_TEST_LAUNCHCTL_LOG}"
export SSH_ORIGINAL_COMMAND="path thunderbolt"
result="$(${HELPER})"
check "restart after user stop succeeds" '[[ "${result}" == *"SENDER_STARTED"* ]]'
check "restart after user stop restores marker" '[[ -f "${TB_SENDER_STATE_DIR}/enabled" ]]'
check "restart after user stop kickstarts running app" '/usr/bin/grep -q "kickstart -k gui/501/com.targetbridge.sender.autostart" "${TB_TEST_LAUNCHCTL_LOG}"'

print -- "sender helper tests: ${checks} checks, ${failures} failures"
exit "${failures}"

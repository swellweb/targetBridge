#!/bin/zsh
set -u

TEST_DIR="${0:A:h}"
HELPER="${TEST_DIR}/../../Resources/Recovery/activate-sender.sh"
MOCK_SSH="${TEST_DIR}/mock_recovery_ssh.zsh"
TB_TEST_STATE_ROOT="$(mktemp -d /private/tmp/targetbridge-recovery-helper-test.XXXXXX)"
TB_TEST_LOG="${TB_TEST_STATE_ROOT}/ssh.log"
STATE_DIR="${TB_TEST_STATE_ROOT}/Library/Application Support/TargetBridge/Receiver"
RECOVERY_DIR="${TB_TEST_STATE_ROOT}/Library/Application Support/TargetBridge/Recovery"
LAST_TARGET_FILE="${STATE_DIR}/last-working-mac-mini"
PAIRED_TARGET_FILE="${STATE_DIR}/paired-mac-mini"
SENDER_USER_FILE="${STATE_DIR}/paired-mac-mini-user"
typeset -i checks=0
typeset -i failures=0

trap '/bin/rm -rf "${TB_TEST_STATE_ROOT}"' EXIT

# Production credentials are provisioned per iMac and deliberately excluded
# from both source control and the application bundle. The mock SSH transport
# only needs placeholder files so this test exercises target ordering/state.
/bin/mkdir -p "${RECOVERY_DIR}"
print -r -- "test-private-key" > "${RECOVERY_DIR}/id_ed25519_targetbridge_recovery"
print -r -- "test-host-pin" > "${RECOVERY_DIR}/known_hosts"
/bin/mkdir -p "${STATE_DIR}"
print -r -- "operator" > "${SENDER_USER_FILE}"

check_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    checks+=1
    if [[ "${actual}" != "${expected}" ]]; then
        print -u2 -- "FAIL: ${label}: expected '${expected}', got '${actual}'"
        failures+=1
    fi
}

result="$(TB_STATE_HOME="${TB_TEST_STATE_ROOT}" \
           TB_SSH_BIN="${MOCK_SSH}" \
           TB_MOCK_SSH_LOG="${TB_TEST_LOG}" \
           /bin/zsh "${HELPER}" "path auto")"
check_equal "${result}" "SENDER_STARTED:mac-mini.local" "default mDNS target"
check_equal "$(<"${LAST_TARGET_FILE}")" "mac-mini.local" "working target cache"

result="$(TB_STATE_HOME="${TB_TEST_STATE_ROOT}" \
           TB_SSH_BIN="${MOCK_SSH}" \
           /bin/zsh "${HELPER}" "input on")"
check_equal "${result}" "INPUT_SET:receiver:mac-mini.local" "input preference action"

/bin/mkdir -p "${STATE_DIR}"
print -r -- "paired-macmini.local" > "${PAIRED_TARGET_FILE}"
result="$(TB_STATE_HOME="${TB_TEST_STATE_ROOT}" \
           TB_SSH_BIN="${MOCK_SSH}" \
           TB_MOCK_SSH_LOG="${TB_TEST_LOG}" \
           /bin/zsh "${HELPER}" stop)"
check_equal "${result}" "SENDER_STOPPED:paired-macmini.local" "paired target priority"
check_equal "$(<"${LAST_TARGET_FILE}")" "paired-macmini.local" "paired target remembered"

result="$(TB_STATE_HOME="${TB_TEST_STATE_ROOT}" \
           TB_SSH_BIN="${MOCK_SSH}" \
           /bin/zsh "${HELPER}" "not allowed" 2>/dev/null)"
command_status=$?
check_equal "${result}" "INVALID_ACTION" "invalid action output"
check_equal "${command_status}" "32" "invalid action status"

first_target="$(/usr/bin/head -n 1 "${TB_TEST_LOG}" | /usr/bin/cut -d'|' -f1)"
last_target="$(/usr/bin/tail -n 1 "${TB_TEST_LOG}" | /usr/bin/cut -d'|' -f1)"
check_equal "${first_target}" "operator@mac-mini.local" "first SSH target"
check_equal "${last_target}" "operator@paired-macmini.local" "paired SSH target"

/bin/rm -f "${PAIRED_TARGET_FILE}" "${LAST_TARGET_FILE}" "${TB_TEST_LOG}"
result="$(TB_STATE_HOME="${TB_TEST_STATE_ROOT}" \
           TB_SSH_BIN="${MOCK_SSH}" \
           TB_MOCK_SSH_LOG="${TB_TEST_LOG}" \
           TB_SENDER_HOST="primary-mini.local" \
           TB_MOCK_SSH_FAIL_TARGETS="operator@primary-mini.local" \
           /bin/zsh "${HELPER}" "path auto")"
check_equal "${result}" "SENDER_STARTED:mac-mini.local" "generic mDNS fallback"
fallback_first="$(/usr/bin/head -n 1 "${TB_TEST_LOG}" | /usr/bin/cut -d'|' -f1)"
fallback_second="$(/usr/bin/sed -n '2p' "${TB_TEST_LOG}" | /usr/bin/cut -d'|' -f1)"
check_equal "${fallback_first}" "operator@primary-mini.local" "configured host is first fallback"
check_equal "${fallback_second}" "operator@mac-mini.local" "generic mDNS target is second fallback"
stale_count="$(/usr/bin/grep -Eic 'private-host|legacy-user@|router\.invalid|192\.168\.|169\.254\.' "${TB_TEST_LOG}" 2>/dev/null || true)"
check_equal "${stale_count}" "0" "no stale hardcoded IP target"

print -- "recovery helper tests: ${checks} checks, ${failures} failures"
exit ${failures}

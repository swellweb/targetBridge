#!/bin/zsh
# Internal TargetBridge Receiver resource. It can execute only the restricted
# actions accepted by the dedicated key installed on the Mac mini.
set -u

STATE_HOME="${TB_STATE_HOME:-${HOME}}"
SSH_BIN="${TB_SSH_BIN:-/usr/bin/ssh}"
LEGACY_DIR="${STATE_HOME}/Library/Application Support/TargetBridge/Recovery"
STATE_DIR="${STATE_HOME}/Library/Application Support/TargetBridge/Receiver"
PAIRED_TARGET_FILE="${STATE_DIR}/paired-mac-mini"
LAST_TARGET_FILE="${STATE_DIR}/last-working-mac-mini"
SENDER_USER_FILE="${STATE_DIR}/paired-mac-mini-user"
RECOVERY_TARGET_FILE="${LEGACY_DIR}/target-host"
KEY_PATH="${LEGACY_DIR}/id_ed25519_targetbridge_recovery"
KNOWN_HOSTS="${LEGACY_DIR}/known_hosts"

KNOWN_HOSTS_OPTION="${KNOWN_HOSTS// /\\ }"
typeset -a TARGETS
typeset -A SEEN_TARGETS
TARGETS=()

add_target() {
    local candidate="${1:-}"
    [[ -n "${candidate}" ]] || return
    [[ "${candidate}" != *[^A-Za-z0-9._-]* ]] || return
    [[ -z "${SEEN_TARGETS[${candidate}]:-}" ]] || return
    TARGETS+=("${candidate}")
    SEEN_TARGETS[${candidate}]=1
}

add_target_file() {
    local file_path="${1:-}"
    local candidate=""
    [[ -r "${file_path}" ]] || return
    IFS= read -r candidate < "${file_path}" || true
    add_target "${candidate}"
}

# The paired and last-working names are tried first. This makes everyday use
# independent from changing DHCP/link-local IP addresses after the first
# successful connection.
add_target_file "${PAIRED_TARGET_FILE}"
add_target_file "${LAST_TARGET_FILE}"
add_target_file "${RECOVERY_TARGET_FILE}"
add_target "${TB_SENDER_HOST:-}"
add_target "mac-mini.local"

remember_working_target() {
    local target="${1:-}"
    [[ -n "${target}" ]] || return
    /bin/mkdir -p "${STATE_DIR}" 2>/dev/null || return
    /bin/chmod 700 "${STATE_DIR}" 2>/dev/null || true
    (umask 077; print -r -- "${target}" > "${LAST_TARGET_FILE}") 2>/dev/null || true
}
LAST_RESULT="MINI_UNREACHABLE"
ACTION="${1:-activate}"

case "${ACTION}" in
    activate|stop|"path auto"|"path thunderbolt"|"path usb"|"path ethernet"|"path wifi"|"input on"|"input off") ;;
    *)
        print -- "INVALID_ACTION"
        exit 32
        ;;
esac

if [[ ! -f "${KEY_PATH}" || ! -f "${KNOWN_HOSTS}" ]]; then
    print -- "RECOVERY_NOT_INSTALLED"
    exit 30
fi

SENDER_USER="${TB_SENDER_USER:-}"
if [[ -z "${SENDER_USER}" && -r "${SENDER_USER_FILE}" ]]; then
    IFS= read -r SENDER_USER < "${SENDER_USER_FILE}" || true
fi
if [[ -z "${SENDER_USER}" ]]; then
    SENDER_USER="$(/usr/bin/id -un 2>/dev/null || true)"
fi
if [[ -z "${SENDER_USER}" || "${SENDER_USER}" == *[^A-Za-z0-9._-]* ]]; then
    print -- "RECOVERY_NOT_CONFIGURED"
    exit 30
fi

for target in "${TARGETS[@]}"; do
    result="$("${SSH_BIN}" \
        -4 \
        -F /dev/null \
        -i "${KEY_PATH}" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o ConnectTimeout=2 \
        -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=yes \
        -o CheckHostIP=no \
        -o HostKeyAlias=targetbridge-macmini \
        -o "UserKnownHostsFile=${KNOWN_HOSTS_OPTION}" \
        -o GlobalKnownHostsFile=/dev/null \
        "${SENDER_USER}@${target}" "${ACTION}" 2>/dev/null)"
    ssh_status=$?

    if [[ ${ssh_status} -eq 0 && "${result}" == *"SENDER_STARTED"* ]]; then
        remember_working_target "${target}"
        print -- "SENDER_STARTED:${target}"
        exit 0
    fi
    if [[ ${ssh_status} -eq 0 && "${result}" == *"SENDER_STOPPED"* ]]; then
        remember_working_target "${target}"
        print -- "SENDER_STOPPED:${target}"
        exit 0
    fi
    if [[ ${ssh_status} -eq 0 && "${result}" == *"INPUT_SET:"* ]]; then
        remember_working_target "${target}"
        print -- "${result}:${target}"
        exit 0
    fi
    if [[ "${result}" == *"LOGIN_REQUIRED"* ]]; then
        print -- "LOGIN_REQUIRED"
        exit 31
    fi
    if [[ -n "${result}" ]]; then
        LAST_RESULT="${result}"
    fi
done

print -- "${LAST_RESULT}"
exit 31

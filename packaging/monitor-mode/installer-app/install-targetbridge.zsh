#!/bin/zsh
set -u

# SSH may forward C.UTF-8 from newer macOS releases to Ventura, where that
# locale is not installed. A stable POSIX locale keeps checks quiet and makes
# the GUI status output deterministic on both Macs.
export LANG=C
export LC_ALL=C

ACTION="${1:-install}"
ROLE="${TB_INSTALL_ROLE:-}"
SCRIPT_DIR="${0:A:h}"
RESOURCE_DIR="${SCRIPT_DIR:h}"
PAYLOAD_DIR="${RESOURCE_DIR}/Payloads"
MANIFEST="${RESOURCE_DIR}/manifest.sha256"
LABEL_RECEIVER="com.targetbridge.receiver.autostart"
LABEL_SENDER="com.targetbridge.sender.autostart"
DOMAIN="gui/$(/usr/bin/id -u)"
ROLLBACK_ACTIVE=0
ROLLBACK_APP=""
ROLLBACK_BACKUP=""
ROLLBACK_FAILED=""
ROLLBACK_SERVICE=""
ROLLBACK_PLIST=""
ROLLBACK_PLIST_BACKUP=""
ROLLBACK_PLIST_CREATED=0
ROLLBACK_HELPER=""
ROLLBACK_HELPER_BACKUP=""
ROLLBACK_STAGE=""

fail() {
    local message="$1"
    print -u2 -- "INSTALL_FAILED:${message}"
    if [[ ${ROLLBACK_ACTIVE} -eq 1 ]]; then
        [[ -z "${ROLLBACK_SERVICE}" ]] ||
            /bin/launchctl kill TERM "${ROLLBACK_SERVICE}" >/dev/null 2>&1 || true
        if [[ -n "${ROLLBACK_APP}" && -e "${ROLLBACK_APP}" ]]; then
            /bin/mv "${ROLLBACK_APP}" "${ROLLBACK_FAILED}" >/dev/null 2>&1 || true
        fi
        if [[ -n "${ROLLBACK_BACKUP}" && -e "${ROLLBACK_BACKUP}" ]]; then
            /bin/mv "${ROLLBACK_BACKUP}" "${ROLLBACK_APP}" >/dev/null 2>&1 || true
        fi
        if [[ -n "${ROLLBACK_HELPER_BACKUP}" && -f "${ROLLBACK_HELPER_BACKUP}" ]]; then
            /bin/cp -p "${ROLLBACK_HELPER_BACKUP}" "${ROLLBACK_HELPER}" >/dev/null 2>&1 || true
        fi
        if [[ -n "${ROLLBACK_PLIST_BACKUP}" && -f "${ROLLBACK_PLIST_BACKUP}" ]]; then
            /bin/cp -p "${ROLLBACK_PLIST_BACKUP}" "${ROLLBACK_PLIST}" >/dev/null 2>&1 || true
        elif [[ ${ROLLBACK_PLIST_CREATED} -eq 1 && -f "${ROLLBACK_PLIST}" ]]; then
            [[ -z "${ROLLBACK_SERVICE}" ]] ||
                /bin/launchctl bootout "${ROLLBACK_SERVICE}" >/dev/null 2>&1 || true
            /bin/mv "${ROLLBACK_PLIST}" "${ROLLBACK_PLIST}.failed" >/dev/null 2>&1 || true
        fi
        if [[ -n "${ROLLBACK_SERVICE}" && -n "${ROLLBACK_PLIST}" && -f "${ROLLBACK_PLIST}" ]]; then
            /bin/launchctl bootout "${ROLLBACK_SERVICE}" >/dev/null 2>&1 || true
            /bin/launchctl bootstrap "${DOMAIN}" "${ROLLBACK_PLIST}" >/dev/null 2>&1 || true
            /bin/launchctl kickstart -k "${ROLLBACK_SERVICE}" >/dev/null 2>&1 || true
        fi
        print -u2 -- "ROLLBACK_COMPLETED:${ROLLBACK_BACKUP}"
    fi
    [[ -z "${ROLLBACK_STAGE}" || ! -d "${ROLLBACK_STAGE}" ]] ||
        /bin/rm -R "${ROLLBACK_STAGE}" >/dev/null 2>&1 || true
    exit 1
}

expected_hash() {
    local relative_path="$1"
    /usr/bin/awk -v wanted="${relative_path}" '$2 == wanted { print $1; exit }' "${MANIFEST}"
}

verify_resource() {
    local relative_path="$1"
    local file_path="${RESOURCE_DIR}/${relative_path}"
    local expected="$(expected_hash "${relative_path}")"
    [[ -n "${expected}" && -r "${file_path}" ]] || fail "RESOURCE_MISSING:${relative_path}"
    local actual="$(/usr/bin/shasum -a 256 "${file_path}" | /usr/bin/awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || fail "ARCHIVE_HASH:${relative_path}"
}

detect_role() {
    if [[ "${ROLE}" == "receiver" || "${ROLE}" == "sender" ]]; then
        return
    fi
    case "$(/usr/bin/uname -m)" in
        x86_64) ROLE="receiver" ;;
        arm64) ROLE="sender" ;;
        *) fail "ARCHITECTURE" ;;
    esac
}

verify_payloads() {
    [[ -r "${MANIFEST}" ]] || fail "MANIFEST_MISSING"
    verify_resource "Payloads/TargetBridge-Receiver.zip"
    verify_resource "Payloads/TargetBridge-Sender.zip"
    verify_resource "Support/targetbridge-restart-sender"
    verify_resource "Support/com.targetbridge.sender.autostart.template.plist"
    print -- "PAYLOADS_OK"
}

receiver_plist() {
    local destination="$1"
    /bin/mkdir -p "${destination:h}" "${HOME}/Library/Logs" || return 1
    /bin/cat > "${destination}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${LABEL_RECEIVER}</string>
<key>ProgramArguments</key><array>
<string>${HOME}/Applications/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver</string>
</array>
<key>RunAtLoad</key><true/>
<!-- Receiver is the iMac's local control surface. It persists monitor mode as
     stopped before a clean quit, then launchd restores the dashboard. -->
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>LimitLoadToSessionType</key><array><string>Aqua</string></array>
<key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>${HOME}/Library/Logs/TargetBridgeReceiver.launchd.out.log</string>
<key>StandardErrorPath</key><string>${HOME}/Library/Logs/TargetBridgeReceiver.launchd.err.log</string>
</dict></plist>
EOF
    /bin/chmod 600 "${destination}"
}

sender_plist() {
    local destination="$1"
    local template="${RESOURCE_DIR}/Support/com.targetbridge.sender.autostart.template.plist"
    /bin/mkdir -p "${destination:h}" "${HOME}/Library/Logs" || return 1
    /usr/bin/sed "s|__TARGETBRIDGE_HOME__|${HOME}|g" "${template}" > "${destination}" || return 1
    /usr/bin/plutil -lint "${destination}" >/dev/null 2>&1 || return 1
    /bin/chmod 600 "${destination}"
}

verify_receiver_install() {
    local app="${HOME}/Applications/TargetBridge Receiver.app"
    local plist="${HOME}/Library/LaunchAgents/${LABEL_RECEIVER}.plist"
    [[ -x "${app}/Contents/MacOS/TargetBridgeReceiver" ]] || fail "RECEIVER_APP_MISSING"
    /usr/bin/file "${app}/Contents/MacOS/TargetBridgeReceiver" | /usr/bin/grep -q x86_64 || fail "ARCHITECTURE"
    /usr/bin/codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || fail "SIGNATURE"
    [[ -f "${plist}" ]] || fail "RECEIVER_AGENT_MISSING"
    /usr/bin/plutil -lint "${plist}" >/dev/null 2>&1 || fail "RECEIVER_AGENT_INVALID"
    /bin/launchctl print "${DOMAIN}/${LABEL_RECEIVER}" 2>/dev/null | /usr/bin/grep -q 'state = running' || fail "RECEIVER_NOT_RUNNING"
    print -- "VERIFY_OK:receiver"
}

install_receiver() {
    local archive="${PAYLOAD_DIR}/TargetBridge-Receiver.zip"
    local app="${HOME}/Applications/TargetBridge Receiver.app"
    local plist="${HOME}/Library/LaunchAgents/${LABEL_RECEIVER}.plist"
    local service="${DOMAIN}/${LABEL_RECEIVER}"
    local stage="$(/usr/bin/mktemp -d /private/tmp/targetbridge-integrated-receiver.XXXXXX)" || fail "TEMP_DIR"
    local stamp="$(/bin/date +%Y%m%d-%H%M%S)"
    local backup="${app}.backup-${stamp}"
    local candidate="${stage}/TargetBridge Receiver.app"
    local plist_backup="${plist}.backup-${stamp}"
    ROLLBACK_STAGE="${stage}"

    /usr/bin/ditto -x -k "${archive}" "${stage}" || fail "ARCHIVE_EXTRACT"
    [[ -x "${candidate}/Contents/MacOS/TargetBridgeReceiver" ]] || fail "RECEIVER_PAYLOAD_MISSING"
    /usr/bin/file "${candidate}/Contents/MacOS/TargetBridgeReceiver" | /usr/bin/grep -q x86_64 || fail "ARCHITECTURE"
    /usr/bin/codesign --verify --deep --strict "${candidate}" >/dev/null 2>&1 || fail "SIGNATURE"
    /bin/mkdir -p "${HOME}/Applications" || fail "PERMISSION"
    if [[ -e "${app}" ]]; then
        /bin/mv "${app}" "${backup}" || fail "BACKUP"
    fi
    /bin/mv "${candidate}" "${app}" || {
        [[ ! -e "${backup}" ]] || /bin/mv "${backup}" "${app}" >/dev/null 2>&1
        fail "PERMISSION"
    }
    ROLLBACK_ACTIVE=1
    ROLLBACK_APP="${app}"
    ROLLBACK_BACKUP="${backup}"
    ROLLBACK_FAILED="${app}.failed-${stamp}"
    ROLLBACK_SERVICE="${service}"
    ROLLBACK_PLIST="${plist}"

    if [[ -f "${plist}" ]]; then
        /bin/cp -p "${plist}" "${plist_backup}" || fail "RECEIVER_AGENT_BACKUP"
        ROLLBACK_PLIST_BACKUP="${plist_backup}"
    else
        ROLLBACK_PLIST_CREATED=1
    fi
    # Rewrite and re-register on every upgrade. Existing R14 installations use
    # SuccessfulExit=false; merely replacing the plist on disk leaves launchd
    # running that old definition until the next login.
    receiver_plist "${plist}" || fail "RECEIVER_AGENT_CREATE"
    /bin/launchctl bootout "${service}" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "${DOMAIN}" "${plist}" >/dev/null 2>&1 || fail "RECEIVER_AGENT_LOAD"
    /bin/launchctl enable "${service}" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "${service}" >/dev/null 2>&1 || fail "RECEIVER_NOT_RUNNING"
    for wait_index in {1..120}; do
        local receiver_pid="$(/bin/launchctl print "${service}" 2>/dev/null |
            /usr/bin/awk '/pid = / {print $3; exit}')"
        if [[ -n "${receiver_pid}" ]] &&
           /usr/sbin/lsof -nP -a -p "${receiver_pid}" -iTCP:54321 -sTCP:LISTEN >/dev/null 2>&1; then
            ROLLBACK_ACTIVE=0
            print -- "INSTALL_OK:receiver:PID=${receiver_pid}:BACKUP=${backup}:PLIST_BACKUP=${plist_backup}"
            /bin/rm -R "${stage}" >/dev/null 2>&1 || true
            return 0
        fi
        /bin/sleep 0.1
    done
    fail "RECEIVER_NOT_RUNNING"
}

verify_sender_install() {
    local app="/Applications/TargetBridge.app"
    local plist="${HOME}/Library/LaunchAgents/${LABEL_SENDER}.plist"
    local helper="${HOME}/.ssh/targetbridge-restart-sender"
    [[ -x "${app}/Contents/MacOS/TargetBridge" ]] || fail "SENDER_APP_MISSING"
    /usr/bin/file "${app}/Contents/MacOS/TargetBridge" | /usr/bin/grep -q arm64 || fail "ARCHITECTURE"
    /usr/bin/codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || fail "SIGNATURE"
    [[ -f "${plist}" && -x "${helper}" ]] || fail "SENDER_AGENT_MISSING"
    /usr/bin/grep -q '<key>PathState</key>' "${plist}" || fail "SENDER_AGENT_OLD"
    /bin/launchctl print "${DOMAIN}/${LABEL_SENDER}" 2>/dev/null | /usr/bin/grep -q 'state = running' || fail "SENDER_NOT_RUNNING"
    print -- "VERIFY_OK:sender"
}

install_sender() {
    local archive="${PAYLOAD_DIR}/TargetBridge-Sender.zip"
    local app="/Applications/TargetBridge.app"
    local plist="${HOME}/Library/LaunchAgents/${LABEL_SENDER}.plist"
    local helper="${HOME}/.ssh/targetbridge-restart-sender"
    local state_dir="${HOME}/Library/Application Support/TargetBridge/Sender"
    local enabled="${state_dir}/enabled"
    local requested_path="${state_dir}/requested-path"
    local service="${DOMAIN}/${LABEL_SENDER}"
    local stage="$(/usr/bin/mktemp -d /private/tmp/targetbridge-integrated-sender.XXXXXX)" || fail "TEMP_DIR"
    local stamp="$(/bin/date +%Y%m%d-%H%M%S)"
    local backup="${app}.backup-${stamp}"
    local candidate="${stage}/TargetBridge.app"
    local needs_registration=0
    local helper_backup="${helper}.backup-${stamp}"
    local plist_backup="${plist}.backup-${stamp}"
    ROLLBACK_STAGE="${stage}"

    /usr/bin/ditto -x -k "${archive}" "${stage}" || fail "ARCHIVE_EXTRACT"
    [[ -x "${candidate}/Contents/MacOS/TargetBridge" ]] || fail "SENDER_PAYLOAD_MISSING"
    /usr/bin/file "${candidate}/Contents/MacOS/TargetBridge" | /usr/bin/grep -q arm64 || fail "ARCHITECTURE"
    /usr/bin/codesign --verify --deep --strict "${candidate}" >/dev/null 2>&1 || fail "SIGNATURE"
    if [[ -e "${app}" ]]; then
        /bin/mv "${app}" "${backup}" || fail "PERMISSION"
    fi
    /bin/mv "${candidate}" "${app}" || {
        [[ ! -e "${backup}" ]] || /bin/mv "${backup}" "${app}" >/dev/null 2>&1
        fail "PERMISSION"
    }
    ROLLBACK_ACTIVE=1
    ROLLBACK_APP="${app}"
    ROLLBACK_BACKUP="${backup}"
    ROLLBACK_FAILED="${app}.failed-${stamp}"
    ROLLBACK_SERVICE="${service}"
    ROLLBACK_PLIST="${plist}"
    ROLLBACK_HELPER="${helper}"

    /bin/mkdir -p "${HOME}/.ssh" "${HOME}/Library/LaunchAgents" "${state_dir}" || fail "PERMISSION"
    if [[ -f "${helper}" ]]; then
        /bin/cp -p "${helper}" "${helper_backup}" || fail "HELPER_BACKUP"
        ROLLBACK_HELPER_BACKUP="${helper_backup}"
    fi
    /bin/cp "${RESOURCE_DIR}/Support/targetbridge-restart-sender" "${helper}" || fail "HELPER_INSTALL"
    /bin/chmod 700 "${helper}" "${state_dir}" >/dev/null 2>&1 || true

    if [[ ! -f "${plist}" ]] || ! /usr/bin/grep -q '<key>PathState</key>' "${plist}"; then
        if [[ -f "${plist}" ]]; then
            /bin/cp -p "${plist}" "${plist_backup}" || fail "PLIST_BACKUP"
            ROLLBACK_PLIST_BACKUP="${plist_backup}"
        else
            ROLLBACK_PLIST_CREATED=1
        fi
        sender_plist "${plist}" || fail "PLIST_INSTALL"
        needs_registration=1
    fi
    [[ -f "${requested_path}" ]] || print -r -- "automatic" > "${requested_path}" || fail "PATH_STATE"
    /usr/bin/touch "${enabled}" || fail "ENABLED_STATE"
    /bin/chmod 600 "${requested_path}" "${enabled}" >/dev/null 2>&1 || true

    if ! /bin/launchctl print "${service}" >/dev/null 2>&1; then
        needs_registration=1
    fi
    if [[ ${needs_registration} -eq 1 ]]; then
        /bin/launchctl bootout "${service}" >/dev/null 2>&1 || true
        /bin/launchctl bootstrap "${DOMAIN}" "${plist}" >/dev/null 2>&1 || fail "SENDER_AGENT_LOAD"
        /bin/launchctl enable "${service}" >/dev/null 2>&1 || true
    fi
    /bin/launchctl kickstart -k "${service}" >/dev/null 2>&1 || fail "SENDER_NOT_RUNNING"
    for wait_index in {1..180}; do
        /bin/launchctl print "${service}" 2>/dev/null | /usr/bin/grep -q 'state = running' && {
            ROLLBACK_ACTIVE=0
            print -- "INSTALL_OK:sender:BACKUP=${backup}"
            /bin/rm -R "${stage}" >/dev/null 2>&1 || true
            return 0
        }
        /bin/sleep 0.1
    done
    fail "SENDER_NOT_RUNNING"
}

detect_role
verify_payloads

case "${ACTION}:${ROLE}" in
    verify:receiver) verify_receiver_install ;;
    verify:sender) verify_sender_install ;;
    install:receiver) install_receiver ;;
    install:sender) install_sender ;;
    *) fail "INVALID_ACTION" ;;
esac

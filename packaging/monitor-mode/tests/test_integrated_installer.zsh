#!/bin/zsh
set -u

APP="${1:?pass TargetBridge Installer.app as first argument}"
SCRIPT_DIR="${0:A:h}"
MONITOR_DIR="${SCRIPT_DIR:h}"
INSTALL_SCRIPT="${APP}/Contents/Resources/Support/install-targetbridge.zsh"
TEMPLATE="${APP}/Contents/Resources/Support/com.targetbridge.sender.autostart.template.plist"
RESOURCES="${APP}/Contents/Resources"
typeset -i checks=0
typeset -i failures=0

check() {
    local label="$1"
    shift
    checks+=1
    if "$@"; then
        print -- "OK: ${label}"
    else
        print -u2 -- "FAIL: ${label}"
        failures+=1
    fi
}

has_both_architectures() {
    local archs="$(/usr/bin/lipo -archs "${APP}/Contents/MacOS/TargetBridgeInstaller" 2>/dev/null)"
    [[ " ${archs} " == *" x86_64 "* && " ${archs} " == *" arm64 "* ]]
}

has_no_command_files() {
    [[ -z "$(/usr/bin/find "${APP}" -type f -name '*.command' -print -quit)" ]]
}

manifest_is_valid() {
    (cd "${RESOURCES}" && /usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null)
}

template_is_portable() {
    /usr/bin/grep -q '__TARGETBRIDGE_HOME__' "${TEMPLATE}" &&
        ! /usr/bin/grep -Eq '/Users/[A-Za-z0-9._-]+' "${TEMPLATE}"
}

receiver_agent_is_durable() {
    /usr/bin/grep -A1 '<key>KeepAlive</key>' "${INSTALL_SCRIPT}" |
        /usr/bin/grep -q '<true/>' &&
        /usr/bin/grep -q 'Rewrite and re-register on every upgrade' "${INSTALL_SCRIPT}" &&
        /usr/bin/grep -q 'lsof -nP -a -p.*-iTCP:54321' "${INSTALL_SCRIPT}"
}

check "app bundle exists" test -d "${APP}"
check "Info.plist is valid" /usr/bin/plutil -lint "${APP}/Contents/Info.plist"
check "ad-hoc signature is valid" /usr/bin/codesign --verify --deep --strict "${APP}"
check "Intel and Apple Silicon slices" has_both_architectures
check "payload manifest" manifest_is_valid
check "no visible .command files" has_no_command_files
check "integrated installer syntax" /bin/zsh -n "${INSTALL_SCRIPT}"
check "portable sender login item" template_is_portable
check "durable Receiver login item" receiver_agent_is_durable
check "Receiver payload archive" /usr/bin/unzip -tqq "${RESOURCES}/Payloads/TargetBridge-Receiver.zip"
check "Sender payload archive" /usr/bin/unzip -tqq "${RESOURCES}/Payloads/TargetBridge-Sender.zip"
check "Italian install button" /usr/bin/grep -q 'Installa / aggiorna' "${MONITOR_DIR}/installer-app/TargetBridgeInstaller.swift"
check "Italian verification button" /usr/bin/grep -q 'title: "Verifica"' "${MONITOR_DIR}/installer-app/TargetBridgeInstaller.swift"

print -- "integrated installer tests: ${checks} checks, ${failures} failures"
exit ${failures}

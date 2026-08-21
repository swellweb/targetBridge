#!/bin/zsh
set -u

print -r -- "$*" >> "${TB_TEST_LAUNCHCTL_LOG}"
if [[ -n "${TB_TEST_LAUNCHCTL_FAIL_ACTION:-}" && "${1:-}" == "${TB_TEST_LAUNCHCTL_FAIL_ACTION}" ]]; then
    if [[ -z "${TB_TEST_LAUNCHCTL_FAIL_COUNT:-}" ]]; then
        print -u2 -- "mock launchctl failure: ${1}"
        exit 70
    fi
    occurrence="$(/usr/bin/grep -c "^${1} " "${TB_TEST_LAUNCHCTL_LOG}" 2>/dev/null || true)"
    if (( occurrence <= TB_TEST_LAUNCHCTL_FAIL_COUNT )); then
        print -u2 -- "mock transient launchctl failure: ${1}"
        exit 70
    fi
fi
case "${1:-}" in
    print)
        [[ "${TB_TEST_SERVICE_LOADED:-1}" == "1" ]] || exit 1
        print -- "state = running"
        service_pid="${TB_TEST_SERVICE_PID:-12345}"
        if [[ -n "${TB_TEST_SERVICE_PID_AFTER:-}" && -n "${TB_TEST_SERVICE_PID_SWITCH_AFTER:-}" ]]; then
            print_count="$(/usr/bin/grep -c '^print ' "${TB_TEST_LAUNCHCTL_LOG}" 2>/dev/null || true)"
            if (( print_count > TB_TEST_SERVICE_PID_SWITCH_AFTER )); then
                service_pid="${TB_TEST_SERVICE_PID_AFTER}"
            fi
        fi
        print -- "pid = ${service_pid}"
        ;;
esac
exit 0

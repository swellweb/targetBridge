#!/bin/zsh
set -u

target="${@[-2]:-}"
action="${@[-1]:-}"

if [[ -n "${TB_MOCK_SSH_LOG:-}" ]]; then
    print -r -- "${target}|${action}" >> "${TB_MOCK_SSH_LOG}"
fi

if [[ ",${TB_MOCK_SSH_FAIL_TARGETS:-}," == *",${target},"* ]]; then
    exit 255
fi

case "${action}" in
    stop)
        print -- "SENDER_STOPPED"
        ;;
    activate|"path auto"|"path thunderbolt"|"path usb"|"path ethernet"|"path wifi")
        print -- "SENDER_STARTED"
        ;;
    "input on")
        print -- "INPUT_SET:receiver"
        ;;
    "input off")
        print -- "INPUT_SET:off"
        ;;
    *)
        print -- "INVALID_ACTION"
        exit 32
        ;;
esac

#!/bin/zsh
set -u

print -r -- "$*" >> "${TB_TEST_LAUNCHCTL_LOG}"
case "${1:-}" in
    print)
        [[ "${TB_TEST_SERVICE_LOADED:-1}" == "1" ]] || exit 1
        print -- "state = running"
        ;;
esac
exit 0

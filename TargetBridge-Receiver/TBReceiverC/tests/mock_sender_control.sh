#!/bin/zsh
set -u
case "${1:-}" in
    activate|"path auto"|"path thunderbolt"|"path usb"|"path ethernet")
        print -- "SENDER_STARTED:mock"
        ;;
    stop)
        print -- "SENDER_STOPPED:mock"
        ;;
    "path wifi")
        /bin/sleep 10
        print -- "SENDER_STARTED:mock"
        ;;
    *)
        print -- "INVALID_ACTION"
        exit 32
        ;;
esac

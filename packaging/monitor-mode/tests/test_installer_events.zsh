#!/bin/zsh
set -euo pipefail

TEST_DIR="${0:A:h}"
SOURCE_DIR="${TEST_DIR:h}/installer-app"
BUILD_DIR="$(/usr/bin/mktemp -d /private/tmp/targetbridge-installer-event-tests.XXXXXX)"
trap '/bin/rm -R "${BUILD_DIR}"' EXIT

/usr/bin/xcrun swiftc \
    -module-cache-path "${BUILD_DIR}/ModuleCache" \
    "${SOURCE_DIR}/TargetBridgeInstallerEvent.swift" \
    "${TEST_DIR}/InstallerEventTests.swift" \
    -o "${BUILD_DIR}/InstallerEventTests"

"${BUILD_DIR}/InstallerEventTests"

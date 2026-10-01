#!/bin/zsh
set -euo pipefail

TEST_DIR="${0:A:h}"
SOURCE_DIR="${TEST_DIR:h}/installer-app"
BUILD_DIR="$(/usr/bin/mktemp -d /private/tmp/targetbridge-installer-core-tests.XXXXXX)"
trap '/bin/rm -R "${BUILD_DIR}"' EXIT

/usr/bin/xcrun swiftc \
    -module-cache-path "${BUILD_DIR}/ModuleCache" \
    "${SOURCE_DIR}/TargetBridgeInstallerCore.swift" \
    "${TEST_DIR}/InstallerCoreTests.swift" \
    -o "${BUILD_DIR}/InstallerCoreTests"

"${BUILD_DIR}/InstallerCoreTests"

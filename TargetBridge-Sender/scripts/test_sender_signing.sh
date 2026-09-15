#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/targetbridge-signing-test.XXXXXX")
BASE="${1:?Usage: test_sender_signing.sh signed-TargetBridge.app}"
SIGN="$SCRIPT_DIR/sign_targetbridge_sender_app.sh"
VERIFY="$SCRIPT_DIR/verify_sender_update.sh"
expect_reject() {
    local title="$1"; shift
    if "$@" >"$WORK/rejection.log" 2>&1; then
        print -u2 -- "FAIL: accepted $title"; exit 1
    fi
    print -- "PASS: rejected $title"
}
ditto "$BASE" "$WORK/A.app"
ditto "$BASE" "$WORK/B.app"
# Changing a bundle resource changes the sealed CodeDirectory, reproducing the
# identity risk without launching a capture process or requesting permissions.
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999999' "$WORK/B.app/Contents/Info.plist"
zsh "$SIGN" "$WORK/B.app"
zsh "$VERIFY" "$WORK/A.app" "$WORK/B.app"
HASH_A=$(/usr/bin/shasum -a 256 "$WORK/A.app/Contents/MacOS/TargetBridge")
HASH_B=$(/usr/bin/shasum -a 256 "$WORK/B.app/Contents/MacOS/TargetBridge")
[[ "${HASH_A%% *}" != "${HASH_B%% *}" ]] || { print -u2 'FAIL: fixtures have identical signed executables'; exit 1; }
print -- 'PASS: different signed executable hashes, stable identity'
expect_reject 'missing identity' env TARGETBRIDGE_CODESIGN_IDENTITY= TARGETBRIDGE_SIGNING_CONFIG="$WORK/missing" zsh "$SIGN" "$WORK/B.app"
expect_reject 'unavailable identity' env TARGETBRIDGE_CODESIGN_IDENTITY=0000000000000000000000000000000000000000 zsh "$SIGN" "$WORK/B.app"
expect_reject 'implicit ad-hoc signing' env TARGETBRIDGE_CODESIGN_IDENTITY=- TARGETBRIDGE_ALLOW_ADHOC=0 zsh "$SIGN" "$WORK/B.app"
ditto "$WORK/B.app" "$WORK/Adhoc.app"
TARGETBRIDGE_CODESIGN_IDENTITY=- TARGETBRIDGE_ALLOW_ADHOC=1 zsh "$SIGN" "$WORK/Adhoc.app"
expect_reject 'ad-hoc update' zsh "$VERIFY" "$WORK/A.app" "$WORK/Adhoc.app"
expect_reject 'ad-hoc baseline' zsh "$VERIFY" "$WORK/Adhoc.app" "$WORK/B.app"
ditto "$WORK/B.app" "$WORK/WrongID.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.targetbridge.receiver' "$WORK/WrongID.app/Contents/Info.plist"
expect_reject 'wrong signing bundle ID' zsh "$SIGN" "$WORK/WrongID.app"
expect_reject 'wrong update bundle ID' zsh "$VERIFY" "$WORK/A.app" "$WORK/WrongID.app"
ditto "$WORK/B.app" "$WORK/Tampered.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 888888' "$WORK/Tampered.app/Contents/Info.plist"
expect_reject 'tampered candidate' zsh "$VERIFY" "$WORK/A.app" "$WORK/Tampered.app"
expect_reject 'tampered installed baseline' zsh "$VERIFY" "$WORK/Tampered.app" "$WORK/B.app"
zsh "$VERIFY" "$WORK/A.app" "$WORK/B.app"
print -- "All signing checks passed. Fixtures retained at $WORK; no installed app or TCC setting changed."

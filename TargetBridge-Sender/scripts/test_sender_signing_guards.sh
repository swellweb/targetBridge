#!/bin/zsh
# Negative-path checks that do not need a trusted signing certificate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/targetbridge-signing-guards.XXXXXX")
BASE="${1:?Usage: test_sender_signing_guards.sh TargetBridge.app}"
SIGN="$SCRIPT_DIR/sign_targetbridge_sender_app.sh"
VERIFY="$SCRIPT_DIR/verify_sender_update.sh"
reject_with() {
    local expected="$1"; shift
    if "$@" >"$WORK/rejection.log" 2>&1; then
        print -u2 -- "FAIL: unexpectedly accepted $expected"; exit 1
    fi
    /usr/bin/grep -Fq -- "$expected" "$WORK/rejection.log" || { /bin/cat "$WORK/rejection.log"; exit 1; }
    print -- "PASS: $expected"
}
reject_with 'No persistent signing identity' env TARGETBRIDGE_CODESIGN_IDENTITY= TARGETBRIDGE_SIGNING_CONFIG="$WORK/missing" zsh "$SIGN" --check-identity
reject_with 'exact 40-character certificate fingerprint' env TARGETBRIDGE_CODESIGN_IDENTITY='unverified display name' zsh "$SIGN" --check-identity
reject_with 'not a valid code-signing identity' env TARGETBRIDGE_CODESIGN_IDENTITY=0000000000000000000000000000000000000000 zsh "$SIGN" --check-identity
reject_with 'Ad-hoc signing requires' env TARGETBRIDGE_CODESIGN_IDENTITY=- TARGETBRIDGE_ALLOW_ADHOC=0 zsh "$SIGN" --check-identity
ditto "$BASE" "$WORK/Adhoc.app"
TARGETBRIDGE_CODESIGN_IDENTITY=- TARGETBRIDGE_ALLOW_ADHOC=1 zsh "$SIGN" "$WORK/Adhoc.app"
reject_with 'Ad-hoc identity cannot preserve' zsh "$VERIFY" "$WORK/Adhoc.app" "$WORK/Adhoc.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.targetbridge.receiver' "$WORK/Adhoc.app/Contents/Info.plist"
reject_with 'Wrong bundle identifier' env TARGETBRIDGE_CODESIGN_IDENTITY=- TARGETBRIDGE_ALLOW_ADHOC=1 zsh "$SIGN" "$WORK/Adhoc.app"
reject_with 'Unexpected bundle ID' zsh "$VERIFY" "$WORK/Adhoc.app" "$BASE"
print -- "7 negative checks passed. Persistent-signature and TCC migration tests still require a valid identity and human consent. Fixtures: $WORK"

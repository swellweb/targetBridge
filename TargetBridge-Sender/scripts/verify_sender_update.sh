#!/bin/zsh
set -euo pipefail
fail() { print -u2 -- "Sender update rejected: $*"; exit 1; }
[[ $# -eq 2 ]] || fail "Usage: $0 installed.app candidate.app"
OLD="$1"
NEW="$2"
for APP in "$OLD" "$NEW"; do
    [[ -f "$APP/Contents/Info.plist" && ! -L "$APP" ]] || fail "Invalid app: $APP"
    ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
    [[ "$ID" == com.targetbridge.sender ]] || fail "Unexpected bundle ID: $ID"
    /usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
    DETAILS=$(/usr/bin/codesign -dv "$APP" 2>&1)
    [[ "$DETAILS" != *"Signature=adhoc"* ]] || fail "Ad-hoc identity cannot preserve update permissions. Migrate once to a persistent signer and reapprove in macOS."
done
REQUIREMENT=$(/usr/bin/codesign -d -r- "$OLD" 2>&1 | /usr/bin/sed -nE 's/^#? ?designated => //p')
[[ -n "$REQUIREMENT" ]] || fail "Missing installed identity requirement"
/usr/bin/codesign --verify --deep --strict --all-architectures -R "$REQUIREMENT" "$NEW" || fail "Candidate does not satisfy the installed Sender identity"
print -- "PASS: candidate satisfies the installed Sender identity on every architecture."
print -- "This verifies signing continuity, not a TCC grant. Install at /Applications/TargetBridge.app without re-signing."

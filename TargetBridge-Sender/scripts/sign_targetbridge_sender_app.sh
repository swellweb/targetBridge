#!/bin/zsh
set -euo pipefail

fail() { print -u2 -- "Sender signing: $*"; exit 1; }
APP="${1:-}"
[[ -n "$APP" && $# -eq 1 ]] || fail "Usage: $0 TargetBridge.app | --check-identity"

CONFIG="${TARGETBRIDGE_SIGNING_CONFIG:-$HOME/Library/Application Support/TargetBridge/Build/sender-signing-identity.txt}"
IDENTITY="${TARGETBRIDGE_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$CONFIG" ]]; then
    IDENTITY=$(<"$CONFIG")
fi
if [[ -z "$IDENTITY" ]]; then
    fail "No persistent signing identity. Configure TARGETBRIDGE_CODESIGN_IDENTITY or $CONFIG. See docs/Sender-Signing.md. Refusing an implicit ad-hoc build."
fi
if [[ "$IDENTITY" == - ]]; then
    [[ "${TARGETBRIDGE_ALLOW_ADHOC:-0}" == 1 ]] || fail "Ad-hoc signing requires TARGETBRIDGE_ALLOW_ADHOC=1; updates may lose privacy permissions."
    print -u2 -- "WARNING: disposable ad-hoc development build; do not install over a persistent signed Sender."
else
    [[ "$IDENTITY" =~ '^[[:xdigit:]]{40}$' ]] || fail "Use the exact 40-character certificate fingerprint, not a display name"
    IDENTITIES=$(/usr/bin/security find-identity -v -p codesigning)
    [[ "${(U)IDENTITIES}" == *" ${(U)IDENTITY} "* ]] || fail "Configured certificate is not a valid code-signing identity in this user's Keychain. Unlock/configure it through macOS; no fallback is allowed."
fi
[[ "$APP" != --check-identity ]] || { print -- 'Signing identity preflight passed'; exit 0; }
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" && ! -L "$APP" ]] || fail "Expected a real application bundle"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
[[ "$BUNDLE_ID" == com.targetbridge.sender ]] || fail "Wrong bundle identifier: $BUNDLE_ID"

# Use the system-generated designated requirement. Never weaken it to just a
# bundle identifier: certificate-bound identity is what makes updates trustworthy.
/usr/bin/codesign --force --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
DETAILS=$(/usr/bin/codesign -dv "$APP" 2>&1)
if [[ "$IDENTITY" != - && "$DETAILS" == *"Signature=adhoc"* ]]; then
    fail "A persistent signature was requested but the result is ad-hoc"
fi
/usr/bin/codesign -d -r- "$APP" 2>&1
print -- "Sender signature verified: $APP"

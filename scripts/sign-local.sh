#!/bin/bash
# Signs the installed TargetBridge apps with your own code-signing certificate,
# so macOS keeps Screen Recording, Accessibility and Input Monitoring across
# updates. Run it after every update, before the first launch:
#
#   bash sign-local.sh                     # both apps in /Applications
#   bash sign-local.sh "/path/to/App.app"  # specific apps
#
# Needs a code-signing certificate in your login keychain, trusted for code
# signing (see docs/Sender-Signing.md). Set TB_SIGN_IDENTITY to use another
# certificate than the one whose name contains "TargetBridge Code Signing".
set -euo pipefail

NAME="${TB_SIGN_IDENTITY:-TargetBridge Code Signing}"

fail() { echo "sign-local: $*" >&2; exit 1; }

# The certificate's SHA-1 fingerprint, so a similarly named one can't be picked.
IDENTITY=$(/usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F "$NAME" | /usr/bin/head -n1 | /usr/bin/awk '{print $2}' || true)
[[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]] || fail "No valid code-signing certificate named \"$NAME\" in your keychain.
Import TargetBridge-CodeSigning.p12 and trust it for code signing first (docs/Sender-Signing.md)."

if [[ $# -gt 0 ]]; then
    APPS=("$@")
else
    APPS=()
    for app in "/Applications/TargetBridge.app" "/Applications/TargetBridge Receiver.app"; do
        [[ -d "$app" ]] && APPS+=("$app")
    done
    [[ ${#APPS[@]} -gt 0 ]] || fail "No TargetBridge app found in /Applications."
fi

for app in "${APPS[@]}"; do
    [[ -d "$app" && -f "$app/Contents/Info.plist" ]] || fail "Not an app bundle: $app"
    echo "Signing $app"
    # Downloaded apps are quarantined; the new signature replaces the old one.
    /usr/bin/xattr -cr "$app"
    # Nested code first: the Sender's audio driver, the Receiver's libraries.
    if [[ -d "$app/Contents/PlugIns" ]]; then
        while IFS= read -r -d '' plugin; do
            /usr/bin/codesign --force --sign "$IDENTITY" "$plugin"
        done < <(/usr/bin/find "$app/Contents/PlugIns" -maxdepth 1 \( -name '*.driver' -o -name '*.appex' -o -name '*.bundle' \) -print0)
    fi
    if [[ -d "$app/Contents/Frameworks" ]]; then
        while IFS= read -r -d '' library; do
            /usr/bin/codesign --force --sign "$IDENTITY" "$library"
        done < <(/usr/bin/find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0)
        while IFS= read -r -d '' framework; do
            /usr/bin/codesign --force --sign "$IDENTITY" "$framework"
        done < <(/usr/bin/find "$app/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)
    fi
    /usr/bin/codesign --force --sign "$IDENTITY" "$app"
    /usr/bin/codesign --verify --deep --strict "$app"
    echo "  ok: $(/usr/bin/codesign -dv "$app" 2>&1 | /usr/bin/grep -E '^Authority=' | /usr/bin/head -n1)"
done
echo "Done. macOS keeps the permissions of apps signed with this certificate."

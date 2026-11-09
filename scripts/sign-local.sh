#!/bin/bash
# Signs TargetBridge apps with your own code-signing certificate, so macOS
# keeps Screen Recording, Accessibility and Input Monitoring across updates.
#
#   bash sign-local.sh                 # everything in this script's folder
#   bash sign-local.sh --applications  # the apps installed in /Applications
#   bash sign-local.sh "/path/App.app" # specific apps
#
# Default: put this script in a folder together with the downloads (Sender
# and Receiver, Apple silicon and Intel, zipped or unzipped) and run it. It
# unpacks the zips into one folder per download, signs every app it finds in
# one go and shows which app belongs on which Mac. Then copy the apps to the
# Applications folder of each Mac, or let the script install the ones for
# this Mac.
#
# Needs a code-signing certificate in your login keychain, trusted for code
# signing (see docs/Sender-Signing.md). Set TB_SIGN_IDENTITY to use another
# certificate than the one whose name contains "TargetBridge Code Signing".
set -euo pipefail

NAME="${TB_SIGN_IDENTITY:-TargetBridge Code Signing}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "sign-local: $*" >&2; exit 1; }

# The certificate's SHA-1 fingerprint, so a similarly named one can't be picked.
IDENTITY=$(/usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F "$NAME" | /usr/bin/head -n1 | /usr/bin/awk '{print $2}' || true)
[[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]] || fail "No valid code-signing certificate named \"$NAME\" in your keychain.
Create or import it and trust it for code signing first (docs/Sender-Signing.md)."

# Unpacks every zip in the folder (and a zip found inside one, as GitHub
# downloads contain the zipped app) into a folder named after the zip.
unpack_zips() {
    local dir="$1" pass zip base target
    for pass in 1 2; do
        while IFS= read -r -d '' zip; do
            base="$(basename "$zip")"
            base="${base%.zip}"
            base="${base%.app}"
            target="$(dirname "$zip")/$base"
            # Already unpacked (an app inside): leave it.
            if [[ -d "$target" ]] && /usr/bin/find "$target" -maxdepth 2 -name '*.app' -type d | /usr/bin/grep -q .; then
                continue
            fi
            echo "Unpacking $(basename "$zip")"
            /bin/mkdir -p "$target"
            /usr/bin/ditto -x -k "$zip" "$target"
        done < <(/usr/bin/find "$dir" -maxdepth 3 -name '*.zip' -type f -print0)
    done
}

# Every app bundle in the folder, but not apps nested inside other apps.
find_apps() {
    /usr/bin/find "$1" -maxdepth 4 -name '*.app' -type d -prune -print0
}

app_architectures() {
    local exe
    exe="$(/usr/bin/defaults read "$1/Contents/Info" CFBundleExecutable 2>/dev/null || true)"
    [[ -n "$exe" && -f "$1/Contents/MacOS/$exe" ]] || { echo "unknown"; return; }
    /usr/bin/lipo -archs "$1/Contents/MacOS/$exe" 2>/dev/null || echo "unknown"
}

sign_app() {
    local app="$1"
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
}

APPS=()
FOLDER_MODE=0
if [[ $# -gt 0 && "$1" == "--applications" ]]; then
    for app in "/Applications/TargetBridge.app" "/Applications/TargetBridge Receiver.app"; do
        [[ -d "$app" ]] && APPS+=("$app")
    done
    [[ ${#APPS[@]} -gt 0 ]] || fail "No TargetBridge app found in /Applications."
elif [[ $# -gt 0 ]]; then
    APPS=("$@")
else
    FOLDER_MODE=1
    unpack_zips "$SCRIPT_DIR"
    while IFS= read -r -d '' app; do
        APPS+=("$app")
    done < <(find_apps "$SCRIPT_DIR")
    [[ ${#APPS[@]} -gt 0 ]] || fail "No apps or zips found in $SCRIPT_DIR.
Put this script in the folder with the TargetBridge downloads, or run: bash sign-local.sh --applications"
fi

for app in "${APPS[@]}"; do
    sign_app "$app"
done

echo
echo "Signed apps:"
for app in "${APPS[@]}"; do
    archs="$(app_architectures "$app")"
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) mac="any Mac" ;;
        *arm64*) mac="Macs with Apple silicon" ;;
        *x86_64*) mac="Intel Macs" ;;
        *) mac="unknown Mac" ;;
    esac
    echo "  $(basename "$app")  ($archs, for $mac)"
    echo "    $app"
done

# Folder mode: offer to install the apps that run on this Mac.
if [[ $FOLDER_MODE -eq 1 && -t 0 ]]; then
    this_arch="$(/usr/bin/uname -m)"
    echo
    for app in "${APPS[@]}"; do
        archs="$(app_architectures "$app")"
        [[ "$archs" == *"$this_arch"* ]] || continue
        name="$(basename "$app")"
        read -r -p "Install $name ($archs) into /Applications on this Mac? [y/N] " answer
        [[ "$answer" =~ ^[Yy] ]] || continue
        if /usr/bin/pgrep -xq "$(/usr/bin/defaults read "$app/Contents/Info" CFBundleExecutable)"; then
            echo "  Quit $name first, then run the script again."
            continue
        fi
        /bin/rm -rf "/Applications/$name"
        # ditto keeps the signature intact.
        /usr/bin/ditto "$app" "/Applications/$name"
        /usr/bin/codesign --verify --strict "/Applications/$name"
        echo "  installed /Applications/$name"
    done
fi

echo
echo "Done. Copy each app into the Applications folder of the Mac it belongs to."
echo "macOS keeps the permissions of apps signed with this certificate."

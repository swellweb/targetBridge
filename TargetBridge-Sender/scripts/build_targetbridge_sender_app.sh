#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DERIVED_DATA_DIR="${ROOT}/.build/DerivedData"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}"
SOURCE_APP="${BUILD_DIR}/TargetBridge.app"
DEST_DIR="${REPO_ROOT}/build"
DEST_APP="${DEST_DIR}/TargetBridge.app"
"$SCRIPT_DIR/sign_targetbridge_sender_app.sh" --check-identity

cd "$ROOT"

xcodegen generate

xcodebuild \
  -scheme TBDisplaySender \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$DEST_DIR"
STAGING_DIR=$(mktemp -d "$DEST_DIR/.sender-signing.XXXXXX")
STAGED_APP="$STAGING_DIR/TargetBridge.app"
ditto "$SOURCE_APP" "$STAGED_APP"
echo "Cleaning extended attributes..."
xattr -cr "$STAGED_APP"
echo "Signing sender application..."
"$SCRIPT_DIR/sign_targetbridge_sender_app.sh" "$STAGED_APP"
if [[ -e "$DEST_APP" ]]; then
  # Retain the old artifact inside the staging directory for recovery.
  mv "$DEST_APP" "$STAGING_DIR/Previous TargetBridge.app"
fi
if ! mv "$STAGED_APP" "$DEST_APP"; then
  if [[ ! -e "$DEST_APP" && -e "$STAGING_DIR/Previous TargetBridge.app" ]]; then
    mv "$STAGING_DIR/Previous TargetBridge.app" "$DEST_APP"
  fi
  echo "Could not activate the signed build; recovery files: $STAGING_DIR" >&2
  exit 1
fi
touch "$DEST_APP"

echo "TargetBridge sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"

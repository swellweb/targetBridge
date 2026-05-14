#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_DIR="${ROOT}/.build/DerivedData"
BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/Debug"
SOURCE_APP="${BUILD_DIR}/TargetBridge.app"
DEST_APP="${HOME}/Desktop/TargetBridge.app"

cd "$ROOT"

xcodegen generate

xcodebuild \
  -scheme TBDisplaySender \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

echo "TargetBridge sender built: $DEST_APP"
echo "DerivedData locale: $DERIVED_DATA_DIR"

#!/usr/bin/env bash
set -euo pipefail

# Builds a Release PRTracker.app with ad hoc signing (no Apple Developer ID),
# copies it to build/, and writes a distributable zip next to it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED="${ROOT}/build/DerivedData"
PRODUCTS="${DERIVED}/Build/Products/Release"
APP_NAME="PRTracker.app"

mkdir -p "${ROOT}/build"

echo "Building Release with CODE_SIGN_IDENTITY=- (ad hoc)..."
xcodebuild \
  -project PRTracker.xcodeproj \
  -scheme PRTracker \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build \
  CODE_SIGN_IDENTITY=-

SOURCE_APP="${PRODUCTS}/${APP_NAME}"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: expected app at $SOURCE_APP" >&2
  exit 1
fi

OUT_APP="${ROOT}/build/${APP_NAME}"
rm -rf "$OUT_APP"
ditto "$SOURCE_APP" "$OUT_APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${OUT_APP}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${OUT_APP}/Contents/Info.plist")"
ZIP_NAME="PRTracker-macos-${VERSION}-b${BUILD}.zip"
ZIP_PATH="${ROOT}/build/${ZIP_NAME}"

rm -f "$ZIP_PATH"
( cd "${ROOT}/build" && zip -rq "$ZIP_NAME" "$APP_NAME" )

echo ""
echo "App bundle: ${OUT_APP}"
echo "Zip archive: ${ZIP_PATH}"
echo "Size: $(du -h "$ZIP_PATH" | awk '{print $1}')"
echo "SHA-256:"
shasum -a 256 "$ZIP_PATH"

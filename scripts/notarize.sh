#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-dmg-or-zip>"
  exit 1
fi

ARTIFACT_PATH="$1"

if [[ -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  cat <<'EOF'
Missing required env vars:
  APPLE_TEAM_ID
  APPLE_ID
  APPLE_APP_SPECIFIC_PASSWORD

Example:
  APPLE_TEAM_ID=TEAMID \
  APPLE_ID=you@example.com \
  APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx \
  ./scripts/notarize.sh build/PRTracker.dmg
EOF
  exit 1
fi

echo "Submitting $ARTIFACT_PATH for notarization..."
xcrun notarytool submit "$ARTIFACT_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait

echo "Stapling ticket..."
xcrun stapler staple "$ARTIFACT_PATH"

echo "Notarization flow completed."


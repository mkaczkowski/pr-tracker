#!/usr/bin/env bash
set -euo pipefail

# Ensure a release tag matches Xcode MARKETING_VERSION (fail fast before CI or local tag push).
# Usage: ./scripts/check-release-tag.sh [vX.Y.Z]
# With no argument, uses GITHUB_REF_NAME (set by GitHub Actions on tag builds).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAG_INPUT="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "$TAG_INPUT" ]]; then
  echo "usage: $0 <tag>   example: $0 v1.0.2" >&2
  echo "(Or run on Actions where GITHUB_REF_NAME is set.)" >&2
  exit 2
fi

TAG_VER="${TAG_INPUT#v}"

MV="$(xcodebuild -project PRTracker.xcodeproj -scheme PRTracker -configuration Release \
  -showBuildSettings 2>/dev/null | grep "MARKETING_VERSION = " | head -1 | awk -F '= ' '{print $2}' | tr -d ' ')"

if [[ -z "$MV" ]]; then
  echo "::error::Could not read MARKETING_VERSION from xcodebuild -showBuildSettings." >&2
  exit 1
fi

if [[ "$TAG_VER" != "$MV" ]]; then
  echo "::error::Git tag '${TAG_INPUT}' implies marketing version '${TAG_VER}', but Xcode MARKETING_VERSION is '${MV}'. Bump Marketing Version (target PRTracker → General), commit, then tag." >&2
  exit 1
fi

echo "OK: tag '${TAG_INPUT}' matches MARKETING_VERSION ${MV}"

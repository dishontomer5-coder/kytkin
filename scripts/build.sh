#!/usr/bin/env bash
# P0-6: One-command build/test for Kytkin.
#   ./scripts/build.sh         generate the project and build the app (Debug)
#   ./scripts/build.sh test    generate the project and run unit tests
set -euo pipefail

cd "$(dirname "$0")/.."

ACTION="${1:-build}"
CONFIG="${CONFIGURATION:-Debug}"
DERIVED="build"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "==> xcodegen generate"
xcodegen generate --quiet

case "$ACTION" in
  build)
    echo "==> xcodebuild build ($CONFIG)"
    xcodebuild -project Kytkin.xcodeproj -scheme Kytkin -configuration "$CONFIG" \
      -destination 'platform=macOS' -derivedDataPath "$DERIVED" build
    APP="$PWD/$DERIVED/Build/Products/$CONFIG/Kytkin.app"
    echo
    echo "Built: $APP"
    echo "Run it with: open \"$APP\""
    ;;
  test)
    echo "==> xcodebuild test"
    xcodebuild -project Kytkin.xcodeproj -scheme Kytkin \
      -destination 'platform=macOS' -derivedDataPath "$DERIVED" test
    ;;
  *)
    echo "usage: $0 [build|test]" >&2
    exit 2
    ;;
esac

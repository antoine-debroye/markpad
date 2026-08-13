#!/usr/bin/env bash
# Generates the Xcode project and builds Markpad.
#
#   ./scripts/build.sh            debug build
#   ./scripts/build.sh release    release build into dist/
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Debug"
if [[ "${1:-}" == "release" ]]; then
    CONFIGURATION="Release"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi

echo "==> Generating Markpad.xcodeproj"
xcodegen generate

echo "==> Building ($CONFIGURATION)"
xcodebuild \
    -project Markpad.xcodeproj \
    -scheme Markpad \
    -configuration "$CONFIGURATION" \
    -derivedDataPath build \
    build

APP="build/Build/Products/$CONFIGURATION/Markpad.app"
echo "==> Built $APP"

if [[ "$CONFIGURATION" == "Release" ]]; then
    mkdir -p dist
    rm -rf "dist/Markpad.app"
    cp -R "$APP" dist/
    echo "==> Copied to dist/Markpad.app"
fi

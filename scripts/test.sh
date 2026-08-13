#!/usr/bin/env bash
# Runs both test suites: the conversion engine and the editor.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> MarkpadCore (conversion engine)"
(cd MarkpadCore && swift test)

echo
echo "==> Markpad (editor)"
xcodegen generate >/dev/null
xcodebuild \
    -project Markpad.xcodeproj \
    -scheme Markpad \
    -configuration Debug \
    -derivedDataPath build \
    test \
    2>&1 | grep -E "Executed [0-9]+ tests|error:|TEST (SUCCEEDED|FAILED)"

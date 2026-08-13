#!/usr/bin/env bash
# Signs, notarizes and staples Markpad for distribution outside the App Store.
#
# Prerequisites (one-off, and they need your Apple Developer account):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. A stored notarytool credential profile:
#        xcrun notarytool store-credentials "markpad" \
#            --apple-id "you@example.com" \
#            --team-id "YOURTEAMID" \
#            --password "app-specific-password"
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-markpad}"

echo "==> Building Release"
./scripts/build.sh release

APP="dist/Markpad.app"
ZIP="dist/Markpad.zip"

# The Quick Look extension is signed before the app that contains it: nested code must be
# sealed first or the outer signature will not validate.
echo "==> Signing"
codesign --force --options runtime --timestamp \
    --entitlements MarkpadQuickLook/MarkpadQuickLook.entitlements \
    --sign "$DEVELOPER_ID" \
    "$APP/Contents/PlugIns/MarkpadQuickLook.appex"

codesign --force --options runtime --timestamp \
    --entitlements Markpad/Markpad.entitlements \
    --sign "$DEVELOPER_ID" \
    "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Submitting for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip after stapling so the distributed archive carries the ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Done: $ZIP"

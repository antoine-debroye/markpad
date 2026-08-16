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
# Versioned to match the disk image, and because Apple rejects a notarisation whose version
# has already been submitted — a name collision here usually means a forgotten version bump.
VERSION="$(./scripts/version.sh | awk '{print $1}')"
ZIP="dist/Markpad-$VERSION.zip"

# Everything nested is signed before the app that contains it: nested code must be sealed
# first or the outer signature will not validate.
echo "==> Signing"

# Sparkle carries its own helpers, and they are signed innermost-first for the same reason.
# Missing one is the usual cause of an update that downloads and then fails to install, with
# an error that does not say which component was at fault. The XPC services only exist in a
# sandboxed build, hence the guard.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
        [[ -e "$xpc" ]] || continue
        codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$xpc"
    done
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
        "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
        "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$SPARKLE"
fi

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

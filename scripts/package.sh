#!/usr/bin/env bash
# Builds Markpad and packages it as a disk image for distribution.
#
#   ./scripts/package.sh            build Release, then package
#   ./scripts/package.sh --no-build package whatever is already in dist/
#
# Produces dist/Markpad-<version>.dmg: the app beside an /Applications symlink, so opening
# the image gives the usual drag-to-install window.
#
# The image is only as trusted as the app inside it. scripts/build.sh signs ad-hoc,
# so a DMG made from it will be blocked by Gatekeeper on someone else's Mac. Run
# scripts/notarize.sh first to sign with a Developer ID, then package.
set -euo pipefail

cd "$(dirname "$0")/.."

VOLUME_NAME="Markpad"
APP="dist/Markpad.app"
# Stamped with the version so successive releases cannot overwrite one another, and so a
# downloaded image says which build it is without being mounted.
VERSION="$(./scripts/version.sh | awk '{print $1}')"
DMG="dist/Markpad-$VERSION.dmg"

if [[ "${1:-}" != "--no-build" ]]; then
    ./scripts/build.sh release
fi

if [[ ! -d "$APP" ]]; then
    echo "$APP is missing. Run ./scripts/build.sh release first." >&2
    exit 1
fi

# Staged in a temporary directory so the disk image contains exactly two items and
# nothing else that happens to be sitting in dist/.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging"
ditto "$APP" "$STAGING/Markpad.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> Built $DMG ($SIZE)"

# The app inside carries its own stapled ticket, so it opens either way. Notarizing the image
# as well means Gatekeeper clears the download itself rather than only what is dragged out of
# it, which is what stops the first-run warning on the disk image. Skipped without a
# DEVELOPER_ID, since a local image has nothing worth notarizing.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-markpad}"
    echo "==> Signing the image"
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
    echo "==> Notarizing the image"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "==> Notarized $DMG"
fi

# Captured rather than piped into `grep -q`: under `set -o pipefail` grep exits on the
# first match, codesign takes SIGPIPE, and the pipeline reports failure — which silently
# skipped this warning.
SIGNATURE="$(codesign -dv "$APP" 2>&1 || true)"
if [[ "$SIGNATURE" == *"Signature=adhoc"* ]]; then
    cat >&2 <<'EOF'

Note: the app inside is ad-hoc signed, so macOS will refuse to open it on another
Mac ("Markpad is damaged"). That is expected for a local build. For a shareable
image, sign and notarize first:

    DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
    ./scripts/package.sh --no-build
EOF
fi

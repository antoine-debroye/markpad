#!/usr/bin/env bash
# Manages the Sparkle update feed.
#
#   ./scripts/appcast.sh setup    one-off: create the signing key and record its public half
#   ./scripts/appcast.sh          build the feed from the notarized archive in dist/
#
# Updates are only as trustworthy as the key that signs them. The private key lives in your
# login keychain and never appears in the repository; only the public half goes into
# project.yml, where Sparkle reads it to verify what it downloads.
set -euo pipefail

cd "$(dirname "$0")/.."

# Sparkle ships its tools inside the resolved package, which only exists once the project has
# been built at least once.
find_tool() {
    local tool
    tool="$(find build/SourcePackages/artifacts -type f -name "$1" -perm -u+x 2>/dev/null \
        | grep -v old_dsa_scripts | head -1)"
    if [[ -z "$tool" ]]; then
        echo "Could not find Sparkle's $1. Run ./scripts/build.sh first." >&2
        exit 1
    fi
    echo "$tool"
}

VERSION="$(./scripts/version.sh | awk '{print $1}')"
REPO="antoine-debroye/markpad"
TAG="v$VERSION"

if [[ "${1:-generate}" == "setup" ]]; then
    GENERATE_KEYS="$(find_tool generate_keys)"

    echo "==> Creating or reading the update signing key"
    # The keychain will ask permission. Nothing is written to the repository by this step;
    # generate_keys reuses an existing key rather than replacing it, so re-running is safe.
    "$GENERATE_KEYS" >/dev/null

    PUBLIC_KEY="$("$GENERATE_KEYS" -p)"
    if [[ -z "$PUBLIC_KEY" ]]; then
        echo "generate_keys did not return a public key" >&2
        exit 1
    fi

    # Recorded in project.yml rather than the generated plist, so regenerating the project
    # cannot quietly drop it and disable updates.
    sed -i '' -E "s|^([[:space:]]*SUPublicEDKey:[[:space:]]*).*$|\1\"$PUBLIC_KEY\"|" project.yml
    command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null

    echo "==> Recorded public key in project.yml: $PUBLIC_KEY"
    echo
    echo "Back up the private key now — losing it means you can never ship another update"
    echo "to anyone already running Markpad, because they will refuse a differently signed one:"
    echo
    echo "    $GENERATE_KEYS -x markpad-private-key.txt"
    echo
    echo "Store that file somewhere safe and offline, then delete it from the working copy."
    exit 0
fi

GENERATE_APPCAST="$(find_tool generate_appcast)"

ARCHIVE="dist/Markpad-$VERSION.zip"
if [[ ! -f "$ARCHIVE" ]]; then
    cat >&2 <<EOF
$ARCHIVE is missing. The feed is built from the notarized archive, so run:

    DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh

An update has to be signed and notarized, or it will download and then refuse to launch.
EOF
    exit 1
fi

PUBLIC_KEY="$(sed -nE 's|^[[:space:]]*SUPublicEDKey:[[:space:]]*"?([^"]*)"?[[:space:]]*$|\1|p' project.yml | head -1)"
if [[ -z "$PUBLIC_KEY" ]]; then
    echo "No SUPublicEDKey in project.yml. Run ./scripts/appcast.sh setup first." >&2
    exit 1
fi

# Sparkle scans a directory of archives, so the zip is staged on its own: pointed at dist/ it
# would also try to make an update out of the disk image.
UPDATES="dist/updates"
mkdir -p "$UPDATES"
cp "$ARCHIVE" "$UPDATES/"

# generate_appcast appends to whatever feed it finds and writes a fresh one otherwise, and
# dist/ is not in the repository — so from a clean checkout it would publish a feed listing
# this release alone, dropping every earlier version. Seeding it with what is currently live
# keeps the history, which is what lets someone several versions behind still be offered an
# update. A 404 is the expected answer before the first release.
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
if [[ ! -f "$UPDATES/appcast.xml" ]]; then
    if curl -fsSL -o "$UPDATES/appcast.xml" "$FEED_URL" 2>/dev/null; then
        echo "==> Seeded the feed from the published one ($(grep -c "<item>" "$UPDATES/appcast.xml") existing releases)"
    else
        echo "==> No published feed yet; starting a new one"
        rm -f "$UPDATES/appcast.xml"
    fi
fi

echo "==> Building the feed for $VERSION"
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    "$UPDATES"

# generate_appcast stamps every entry it writes with this run's prefix, and it rewrites an
# older entry whenever that version's archive is still lying in the directory — which it has
# to be, since that is what deltas are computed against. The result is a URL pointing at the
# wrong release: Markpad-1.1.0.zip under the v1.1.1 tag, which 404s. Each full archive is put
# back under the tag matching its own version. Deltas belong to this release and stay put.
python3 - "$UPDATES/appcast.xml" "$REPO" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
xml = open(path).read()

def retag(match):
    url, version = match.group(0), match.group(1)
    return re.sub(r"/releases/download/[^/]+/",
                  f"/releases/download/v{version}/", url)

fixed, n = re.subn(rf"https://github\.com/{re.escape(repo)}/releases/download/[^/\"]+/Markpad-([0-9]+\.[0-9]+\.[0-9]+)\.zip",
                   retag, xml)
open(path, "w").write(fixed)
print(f"==> Pointed {n} archive URL(s) at their own release")
PY

echo "==> Wrote $UPDATES/appcast.xml"
echo

# Deltas are listed in the feed, so they have to be uploaded alongside it or Sparkle asks for
# a file that is not there. It falls back to the full archive, so the update still works — it
# just silently stops being a few kilobytes instead of a few megabytes.
DELTAS=$(find "$UPDATES" -maxdepth 1 -name "*.delta" | sort)
if [[ -n "$DELTAS" ]]; then
    echo "Deltas built for this release (upload these too, or updates fall back to the full download):"
    for d in $DELTAS; do echo "    $d  ($(du -h "$d" | cut -f1 | tr -d ' '))"; done
    echo
fi

echo "Publish the release:"
echo
echo "    gh release create $TAG \\"
echo "        \"$UPDATES/Markpad-$VERSION.zip\" \\"
echo "        \"$UPDATES/appcast.xml\" \\"
for d in $DELTAS; do echo "        \"$d\" \\"; done
echo "        --repo $REPO --title \"Markpad $VERSION\" --notes \"...\""
echo
echo "SUFeedURL reads the feed from the newest release, so it goes live when that is created."

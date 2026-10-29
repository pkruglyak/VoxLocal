#!/usr/bin/env bash
# Builds, signs and publishes a Sparkle update through GitHub Releases.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
NOTES_FILE="${3:-}"
SPARKLE_ACCOUNT="org.voxlocal.VoxLocal"
SPARKLE_TOOLS="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin"
REPOSITORY="pkruglyak/VoxLocal"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    die "Usage: ./scripts/publish_update.sh <version> <build-number> <release-notes.md>"
fi
[[ -f "$NOTES_FILE" ]] || die "release notes file not found: $NOTES_FILE"
[[ -x "$SPARKLE_TOOLS/generate_appcast" ]] || die "Sparkle tools missing; run: swift package resolve"
command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required"
command -v ditto >/dev/null 2>&1 || die "ditto is required"

cd "$REPO_ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    die "commit or stash source changes before publishing an update"
fi

TAG="v$VERSION"
ARCHIVE="$DIST_DIR/VoxLocal-$VERSION.zip"
APPCAST_WORK="$(mktemp -d "$DIST_DIR/appcast.XXXXXX")"
trap 'rm -rf "$APPCAST_WORK"' EXIT

log "Building VoxLocal $VERSION ($BUILD_NUMBER)…"
VOXLOCAL_VERSION="$VERSION" VOXLOCAL_BUILD_NUMBER="$BUILD_NUMBER" "$REPO_ROOT/scripts/build_app.sh"

# Public builds currently use an ad-hoc app signature plus Sparkle's EdDSA
# archive and feed signatures. Replace this with Developer ID signing when an
# Apple Developer certificate becomes available.
log "Applying the distribution signature…"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
cp "$ARCHIVE" "$APPCAST_WORK/"
cp "$NOTES_FILE" "$APPCAST_WORK/VoxLocal-$VERSION.md"
if [[ -f "$REPO_ROOT/appcast.xml" ]]; then
    cp "$REPO_ROOT/appcast.xml" "$APPCAST_WORK/appcast.xml"
fi

log "Signing the update and generating appcast.xml…"
"$SPARKLE_TOOLS/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
    --link "https://github.com/$REPOSITORY" \
    --embed-release-notes \
    "$APPCAST_WORK"
cp "$APPCAST_WORK/appcast.xml" "$REPO_ROOT/appcast.xml"

log "Publishing GitHub Release ${TAG}…"
gh release create "$TAG" "$ARCHIVE" \
    --repo "$REPOSITORY" \
    --target main \
    --title "VoxLocal $VERSION" \
    --notes-file "$NOTES_FILE"

git add appcast.xml
git commit -m "Publish VoxLocal $VERSION update feed"
git push origin main

log "Published VoxLocal $VERSION. Existing installations will discover it automatically."

#!/usr/bin/env bash
# Builds VoxLocal in release mode and assembles a runnable .app bundle at
# dist/VoxLocal.app.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_clt
cd "$REPO_ROOT"

[[ -x "$WHISPER_CLI" ]] || die "whisper-cli not built. Run ./scripts/bootstrap.sh first."

VERSION="${VOXLOCAL_VERSION:-1.3.0}"
BUILD_NUMBER="${VOXLOCAL_BUILD_NUMBER:-6}"
ICON_FILE="$REPO_ROOT/assets/VoxLocal.icns"

log "Building Swift package (release)…"
swift build -c release --product VoxLocal

BIN="$REPO_ROOT/.build/release/VoxLocal"
RESOURCE_BUNDLE="$REPO_ROOT/.build/release/VoxLocal_VoxLocalCore.bundle"
SPARKLE_FRAMEWORK="$REPO_ROOT/.build/release/Sparkle.framework"
[[ -x "$BIN" ]] || die "release binary missing at $BIN"
[[ -d "$RESOURCE_BUNDLE" ]] || die "resource bundle missing at $RESOURCE_BUNDLE"
[[ -d "$SPARKLE_FRAMEWORK" ]] || die "Sparkle framework missing at $SPARKLE_FRAMEWORK"
[[ -f "$ICON_FILE" ]] || die "app icon missing at $ICON_FILE"

log "Assembling ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$WHISPER_CLI" "$APP_BUNDLE/Contents/MacOS/whisper-cli"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/VoxLocal.icns"

# SwiftPM links Sparkle through @rpath, while a regular app bundle keeps
# third-party frameworks in Contents/Frameworks.
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleDisplayName</key>
    <string>VoxLocal</string>
    <key>CFBundleExecutable</key>
    <string>VoxLocal</string>
    <key>CFBundleIdentifier</key>
    <string>org.voxlocal.VoxLocal</string>
    <key>CFBundleIconFile</key>
    <string>VoxLocal</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VoxLocal</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/pkruglyak/VoxLocal/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>LTd8IDcMRkt4phYQKn5FTlt70aES1QfXMg+EaOT2adU=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>3600</integer>
    <key>SUAllowsAutomaticUpdates</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoxLocal записывает вашу речь для локального распознавания. Звук не покидает этот Mac. / VoxLocal records your speech for on-device transcription. Audio never leaves this Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 VoxLocal contributors. MIT License.</string>
</dict>
</plist>
PLIST

# Localized permission strings.
mkdir -p "$APP_BUNDLE/Contents/Resources/ru.lproj" "$APP_BUNDLE/Contents/Resources/en.lproj"
cat > "$APP_BUNDLE/Contents/Resources/ru.lproj/InfoPlist.strings" <<'EOF'
"NSMicrophoneUsageDescription" = "VoxLocal записывает вашу речь для локального распознавания. Звук не покидает этот Mac.";
EOF
cat > "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings" <<'EOF'
"NSMicrophoneUsageDescription" = "VoxLocal records your speech for on-device transcription. Audio never leaves this Mac.";
EOF

SIGN_IDENTITY="${VOXLOCAL_SIGN_IDENTITY:-VoxLocal Local Code Signing}"
log "Signing with local identity if available…"
if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"; then
    log "Signed with: $SIGN_IDENTITY"
    SIGNED_WITH_LOCAL_IDENTITY=1
else
    log "Local signing identity '$SIGN_IDENTITY' unavailable; falling back to ad-hoc signing."
    codesign --force --deep --sign - "$APP_BUNDLE"
    SIGNED_WITH_LOCAL_IDENTITY=0
fi
VERIFY_LOG="$(mktemp)"
if ! codesign --verify --deep "$APP_BUNDLE" 2>"$VERIFY_LOG"; then
    if [[ "$SIGNED_WITH_LOCAL_IDENTITY" == "1" ]] && grep -q "CSSMERR_TP_NOT_TRUSTED" "$VERIFY_LOG"; then
        log "Signed with local identity, but macOS does not trust that certificate yet."
    else
        cat "$VERIFY_LOG" >&2
        rm -f "$VERIFY_LOG"
        die "codesign verification failed"
    fi
fi
rm -f "$VERIFY_LOG"

log "Done: $APP_BUNDLE"
log "Launch with: ./scripts/run.sh  (or: open \"$APP_BUNDLE\")"

#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# Latent Resonator -- Release Build Script
#
# Produces a notarized DMG ready for distribution.
#
# Prerequisites:
#   1. Xcode installed (not just Command Line Tools)
#   2. Apple Developer account signed in (Xcode > Settings > Accounts)
#   3. Developer ID Application certificate installed in Keychain
#   4. Set environment variables (or the script will prompt):
#        APPLE_ID        -- your Apple ID email
#        APPLE_TEAM_ID   -- 10-char team identifier
#        APP_PASSWORD    -- app-specific password (appleid.apple.com > Security)
#
# Usage:
#   ./scripts/build-release.sh
#
# Output:
#   dist/LatentResonator-<version>.dmg
# ──────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_ROOT/LatentResonator/LatentResonator.xcodeproj"
SCHEME="LatentResonator"
ARCHIVE_DIR="$PROJECT_ROOT/dist/archive"
EXPORT_DIR="$PROJECT_ROOT/dist/export"
DMG_DIR="$PROJECT_ROOT/dist"
EXPORT_OPTIONS="$SCRIPT_DIR/export-options.plist"

# ── Read version from project ──
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | head -1 | sed 's/.*= *\(.*\);/\1/' | tr -d '[:space:]')
BUILD=$(grep 'CURRENT_PROJECT_VERSION' "$PROJECT/project.pbxproj" | head -1 | sed 's/.*= *\(.*\);/\1/' | tr -d '[:space:]')
APP_NAME="LatentResonator"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "──────────────────────────────────────────────"
echo "  Latent Resonator -- Release Build"
echo "  Version: ${VERSION} (${BUILD})"
echo "──────────────────────────────────────────────"

# ── Validate Xcode ──
if ! command -v xcodebuild &>/dev/null; then
    echo "ERROR: xcodebuild not found."
    echo "  Make sure Xcode is installed and run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

# ── Clean previous artifacts ──
rm -rf "$ARCHIVE_DIR" "$EXPORT_DIR"
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR" "$DMG_DIR"

# ── Step 1: Archive ──
echo ""
echo "[1/4] Archiving (Release configuration)..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_DIR/$APP_NAME.xcarchive" \
    -quiet

echo "  Archive created: $ARCHIVE_DIR/$APP_NAME.xcarchive"

# ── Step 2: Export ──
echo ""
echo "[2/4] Exporting with Developer ID signing..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_DIR/$APP_NAME.xcarchive" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Export failed -- $APP_PATH not found."
    echo "  Make sure your Developer ID certificate is installed."
    exit 1
fi
echo "  Exported: $APP_PATH"

# ── Step 3: Notarize ──
echo ""
echo "[3/4] Notarizing with Apple..."

# Check for credentials
if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
    echo ""
    echo "  Notarization credentials not set. To notarize, export:"
    echo "    export APPLE_ID='your@email.com'"
    echo "    export APPLE_TEAM_ID='XXXXXXXXXX'"
    echo "    export APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'"
    echo ""
    echo "  Generate an app-specific password at: https://appleid.apple.com"
    echo "  Find your Team ID at: https://developer.apple.com/account"
    echo ""
    echo "  Skipping notarization -- the app will trigger Gatekeeper warnings."
    echo "  Testers can bypass with: right-click > Open"
    NOTARIZED=false
else
    # Create zip for notarization
    NOTARIZE_ZIP="$EXPORT_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    # Staple the notarization ticket
    xcrun stapler staple "$APP_PATH"
    echo "  Notarization complete and stapled."
    NOTARIZED=true

    rm -f "$NOTARIZE_ZIP"
fi

# ── Step 4: Create DMG ──
echo ""
echo "[4/4] Creating DMG..."

DMG_TEMP="$DMG_DIR/${APP_NAME}-temp.dmg"
DMG_FINAL="$DMG_DIR/$DMG_NAME"

rm -f "$DMG_TEMP" "$DMG_FINAL"

# Create DMG with Applications symlink for drag-install
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$APP_PATH" \
    -ov -format UDRW \
    "$DMG_TEMP" \
    -quiet

# Mount, add Applications symlink, unmount
MOUNT_DIR=$(hdiutil attach "$DMG_TEMP" -nobrowse -quiet | tail -1 | awk '{print $3}')
ln -s /Applications "$MOUNT_DIR/Applications"
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_FINAL" -quiet
rm -f "$DMG_TEMP"

if [ "${NOTARIZED:-false}" = true ]; then
    xcrun stapler staple "$DMG_FINAL"
fi

echo ""
echo "──────────────────────────────────────────────"
echo "  BUILD COMPLETE"
echo ""
echo "  DMG: $DMG_FINAL"
echo "  Size: $(du -h "$DMG_FINAL" | cut -f1)"
if [ "${NOTARIZED:-false}" = true ]; then
    echo "  Status: SIGNED + NOTARIZED (ready for distribution)"
else
    echo "  Status: SIGNED (not notarized -- testers use right-click > Open)"
fi
echo ""
echo "  Upload to GitHub Releases:"
echo "    gh release create v${VERSION} '$DMG_FINAL' --title 'v${VERSION}' --notes 'Beta release'"
echo "──────────────────────────────────────────────"

#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA_DIR="$PROJECT_DIR/build-installer"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/Luma.app"
DIST_DIR="$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luma-dmg.XXXXXX")"

cleanup() {
    case "$STAGING_DIR" in
        */luma-dmg.*) rm -rf "$STAGING_DIR" ;;
    esac
}
trap cleanup EXIT

cd "$PROJECT_DIR"

xcodebuild \
    -project Luma.xcodeproj \
    -scheme Luma \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "No se encontró la aplicación compilada en $APP_PATH"
    exit 1
fi

# This local signature keeps the bundle internally consistent. Public releases
# should replace it with a Developer ID signature and Apple notarization.
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/Luma-${VERSION}-macOS.dmg"

mkdir -p "$DIST_DIR"
if [[ -e "$DMG_PATH" ]]; then
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    DMG_PATH="$DIST_DIR/Luma-${VERSION}-macOS-${TIMESTAMP}.dmg"
fi

ditto "$APP_PATH" "$STAGING_DIR/Luma.app"
ln -s /Applications "$STAGING_DIR/Aplicaciones"
cp "$PROJECT_DIR/Installer/LEEME.txt" "$STAGING_DIR/LEEME.txt"

hdiutil create \
    -volname "Luma" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    "$DMG_PATH"

print "$DMG_PATH"

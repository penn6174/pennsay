#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VoiceInput"
DEFAULT_VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$ROOT_DIR/project.yml" | head -n 1)"
VERSION="${VOICEINPUT_VERSION:-$DEFAULT_VERSION}"
BUILD_ROOT="${VOICEINPUT_BUILD_ROOT:-$HOME/.voiceinput-build}"
BUILD_LINK="$ROOT_DIR/build"
RELEASE_DIR="$ROOT_DIR/build"
SIGNED_APP_NAME="$APP_NAME-v$VERSION.app"
SIGNED_APP_PATH="$RELEASE_DIR/$SIGNED_APP_NAME"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-v$VERSION.zip"
DMG_PATH="$RELEASE_DIR/$APP_NAME-v$VERSION.dmg"
SHA_PATH="$RELEASE_DIR/$APP_NAME-v$VERSION.sha256"
STAGE_DIR="$RELEASE_DIR/dmg-stage"

if [[ -L "$BUILD_LINK" ]]; then
  ln -sfn "$BUILD_ROOT" "$BUILD_LINK"
elif [[ -e "$BUILD_LINK" ]]; then
  rm -rf "$BUILD_LINK"
  ln -s "$BUILD_ROOT" "$BUILD_LINK"
else
  mkdir -p "$BUILD_ROOT"
  ln -s "$BUILD_ROOT" "$BUILD_LINK"
fi

"$ROOT_DIR/scripts/build.sh" Release
rm -rf "$SIGNED_APP_PATH" "$ZIP_PATH" "$DMG_PATH" "$SHA_PATH" "$STAGE_DIR"
cp -R "$ROOT_DIR/build/Release/$APP_NAME.app" "$SIGNED_APP_PATH"
xattr -cr "$SIGNED_APP_PATH"
xattr -d -r com.apple.provenance "$SIGNED_APP_PATH" >/dev/null 2>&1 || true
xattr -d -r com.apple.FinderInfo "$SIGNED_APP_PATH" >/dev/null 2>&1 || true
xattr -d -r com.apple.fileprovider.fpfs#P "$SIGNED_APP_PATH" >/dev/null 2>&1 || true

ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP_PATH" "$ZIP_PATH"

mkdir -p "$STAGE_DIR"
cp -R "$SIGNED_APP_PATH" "$STAGE_DIR/$APP_NAME.app"
xattr -cr "$STAGE_DIR"
xattr -d -r com.apple.provenance "$STAGE_DIR" >/dev/null 2>&1 || true

create-dmg \
  --volname "$APP_NAME Installer" \
  --window-size 640 420 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 180 180 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 460 180 \
  "$DMG_PATH" \
  "$STAGE_DIR"

(
  (cd "$RELEASE_DIR" && tar -cf - "$SIGNED_APP_NAME" | shasum -a 256 | awk '{print $1 "  '"$SIGNED_APP_NAME"'"}')
  shasum -a 256 "$ZIP_PATH" "$DMG_PATH"
) >"$SHA_PATH"

rm -rf "$STAGE_DIR"

echo "Release artifacts:"
echo "  $SIGNED_APP_PATH"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "  $SHA_PATH"

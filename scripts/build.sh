#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
APP_NAME="PennSay"
LEGACY_APP_NAME="VoiceInput"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_ROOT="${PENNSAY_BUILD_ROOT:-${VOICEINPUT_BUILD_ROOT:-$HOME/.voiceinput-build}}"
BUILD_LINK="$ROOT_DIR/build"
BUILD_DIR="$BUILD_ROOT/$CONFIGURATION"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
DEFAULT_VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$ROOT_DIR/project.yml" | head -n 1)"
VERSION="${PENNSAY_VERSION:-${VOICEINPUT_VERSION:-$DEFAULT_VERSION}}"

# Build number strategy (2026-04-22):
#   - Monotonically increasing within a given MARKETING_VERSION
#   - Resets to 1 when MARKETING_VERSION bumps (keyed to tag v${VERSION})
#   - build = (commits since tag v${VERSION}) + 1
#   - If the tag does not yet exist (e.g. first build of a new version, or
#     outside a git checkout), fall back to project.yml's CURRENT_PROJECT_VERSION.
compute_default_build_number() {
  local version="$1"
  local tag="v${version}"
  if command -v git >/dev/null 2>&1 \
      && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && git -C "$ROOT_DIR" rev-parse "$tag" >/dev/null 2>&1; then
    local count
    count=$(git -C "$ROOT_DIR" rev-list "$tag"..HEAD --count 2>/dev/null || echo 0)
    echo $((count + 1))
  else
    sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$ROOT_DIR/project.yml" | head -n 1
  fi
}
DEFAULT_BUILD_NUMBER="$(compute_default_build_number "$VERSION")"
BUILD_NUMBER="${PENNSAY_BUILD_NUMBER:-${VOICEINPUT_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}}"

ensure_build_link() {
  mkdir -p "$BUILD_ROOT"
  if [[ -L "$BUILD_LINK" ]]; then
    ln -sfn "$BUILD_ROOT" "$BUILD_LINK"
  elif [[ -e "$BUILD_LINK" ]]; then
    rm -rf "$BUILD_LINK"
    ln -s "$BUILD_ROOT" "$BUILD_LINK"
  else
    ln -s "$BUILD_ROOT" "$BUILD_LINK"
  fi
}

cd "$ROOT_DIR"
xcodegen generate >/dev/null
ensure_build_link

rm -rf "$APP_BUNDLE" "$BUILD_DIR/$LEGACY_APP_NAME.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

SWIFT_FLAGS=(
  Sources/VoiceInputCore/*.swift
  doubao-murmur/*.swift
  -target arm64-apple-macosx14.0
  -sdk "$SDK_PATH"
  -module-name "$APP_NAME"
  -o "$MACOS_DIR/$APP_NAME"
)

if [[ "$CONFIGURATION" == "Release" ]]; then
  SWIFT_FLAGS+=(-Osize)
else
  SWIFT_FLAGS+=(-g)
fi

echo "Building $APP_NAME ($CONFIGURATION) v$VERSION..."
swiftc "${SWIFT_FLAGS[@]}"

cp "$ROOT_DIR/doubao-murmur/Resources/"*.js "$RESOURCES_DIR/"
cp "$ROOT_DIR/doubao-murmur/Resources/AppIcon.icns" "$RESOURCES_DIR/"
cp "$ROOT_DIR/doubao-murmur/Info.plist" "$INFO_PLIST"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.voiceinput.app" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$INFO_PLIST"

xattr -cr "$APP_BUNDLE" || true
xattr -d -r com.apple.provenance "$APP_BUNDLE" >/dev/null 2>&1 || true
xattr -d -r com.apple.FinderInfo "$APP_BUNDLE" >/dev/null 2>&1 || true
xattr -d -r com.apple.fileprovider.fpfs#P "$APP_BUNDLE" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null

echo "Built app bundle: $APP_BUNDLE"

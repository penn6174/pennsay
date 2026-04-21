#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <dmg-path> [mountpoint] [output-file]" >&2
  exit 64
fi

DMG_INPUT="$1"
MOUNTPOINT="${2:-/tmp/pennsay-test}"
OUTPUT_PATH="${3:-}"
APP_NAME="PennSay.app"

DMG_PATH="$(cd "$(dirname "$DMG_INPUT")" && pwd)/$(basename "$DMG_INPUT")"

cleanup() {
  hdiutil detach "$MOUNTPOINT" >/dev/null 2>&1 || true
  rm -rf "$MOUNTPOINT"
}

trap cleanup EXIT

rm -rf "$MOUNTPOINT"
mkdir -p "$MOUNTPOINT"

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  exec >"$OUTPUT_PATH"
fi

echo "DMG_PATH=$DMG_PATH"
echo "MOUNTPOINT=$MOUNTPOINT"

hdiutil attach "$DMG_PATH" -nobrowse -noverify -noautoopen -mountpoint "$MOUNTPOINT" >/dev/null

ls -la "$MOUNTPOINT"

if [[ -d "$MOUNTPOINT/$APP_NAME" ]]; then
  echo "APP_OK=yes"
else
  echo "APP_OK=no"
  exit 1
fi

if [[ -L "$MOUNTPOINT/Applications" ]]; then
  echo "APPLICATIONS_LINK_OK=yes"
  echo "APPLICATIONS_LINK_TARGET=$(readlink "$MOUNTPOINT/Applications")"
else
  echo "APPLICATIONS_LINK_OK=no"
  exit 1
fi

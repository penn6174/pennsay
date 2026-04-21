#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/Debug/VoiceInput.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
  "$ROOT_DIR/scripts/build.sh" Debug
fi

open -na "$APP_BUNDLE"

#!/bin/bash
# Build and run in one step, with logs streaming
set -e
cd "$(dirname "$0")/.."

echo "🔨 Building..."
xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Debug \
  build \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)'

APP_PATH=$(xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')
APP="$APP_PATH/Doubao Murmur.app"

# Kill existing instance
pkill -x "Doubao Murmur" 2>/dev/null || true
sleep 0.5

echo ""
echo "🚀 Starting Doubao Murmur..."
echo "---"
"$APP/Contents/MacOS/Doubao Murmur" 2>&1

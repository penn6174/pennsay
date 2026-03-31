#!/bin/bash
# Build the app
set -e
cd "$(dirname "$0")/.."

echo "🔨 Building doubao-murmur..."
xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Debug \
  build \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  2>&1 | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED|CompileSwift|Linking)'

echo ""
echo "✅ Build complete"

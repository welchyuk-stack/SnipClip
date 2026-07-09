#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building..."
xcodebuild -project SnipClip.xcodeproj -scheme SnipClip -configuration Debug \
  CONFIGURATION_BUILD_DIR=build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

echo "Signing..."
codesign --force --deep \
  --sign "Apple Development: welchy2003uk@yahoo.co.uk (NZK4VD7566)" \
  --entitlements SnipClip/SnipClip.entitlements \
  build/SnipClip.app

echo "Launching..."
pkill -x SnipClip 2>/dev/null; sleep 0.3
open build/SnipClip.app
echo "Done."

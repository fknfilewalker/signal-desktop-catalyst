#!/bin/bash
# Builds Signal-iOS as a Mac Catalyst app, using the native libraries from
# script/build-catalyst-deps.sh and the settings in Config/Catalyst.xcconfig.
#
# The app is signed ad hoc, so no Apple developer account is needed and the build doesn't
# expire: patches/signal-ios-catalyst.patch removes Signal's need for an app group and keychain
# access group, the entitlements that would require a provisioning profile.
#
#   script/build-catalyst.sh     (SIGNAL_BUNDLEID_PREFIX=com.example to change the bundle ID)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${SIGNAL_BUNDLEID_PREFIX:-local.signalswift}"
CONFIG="${CONFIGURATION:-App Store Release}"
DEPS="$ROOT/build/deps"

# The Pods only ship WebRTC's iOS slices, so their XCFramework step finds nothing for Catalyst and
# leaves this location alone. Put the Catalyst framework there so the Pods' embed-and-sign step
# picks it up like any other framework.
XCFW_DIR="$ROOT/build/DerivedData-Catalyst/Build/Products/$CONFIG-maccatalyst/XCFrameworkIntermediates/SignalRingRTC/WebRTC"
mkdir -p "$XCFW_DIR"
rm -rf "$XCFW_DIR/WebRTC.framework"
cp -R "$DEPS/webrtc-catalyst/WebRTC.framework" "$XCFW_DIR/"

cd "$ROOT/Signal-iOS"
# No -destination: xcodebuild checks destinations against the project file, which doesn't enable
# Catalyst. The macOS SDK with the iosmac variant selects Mac Catalyst without editing it.
xcodebuild \
  -workspace Signal.xcworkspace \
  -scheme Signal \
  -configuration "$CONFIG" \
  -sdk macosx \
  -derivedDataPath "$ROOT/build/DerivedData-Catalyst" \
  -xcconfig "$ROOT/Config/Catalyst.xcconfig" \
  SIGNAL_MAC_DEPS="$DEPS" \
  SIGNAL_MAC_CONFIG="$ROOT/Config" \
  SUPPORTS_MACCATALYST=YES \
  SDK_VARIANT=iosmac \
  SIGNAL_BUNDLEID_PREFIX="$PREFIX" \
  CODE_SIGN_ENTITLEMENTS="$ROOT/Config/Signal-Catalyst.entitlements" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  ENABLE_HARDENED_RUNTIME=NO \
  build

# The share and notification extensions exist to share Signal's app group with the main app.
# Mac builds have no app group (and no push), so leave them out and re-sign the app.
APP="$ROOT/build/DerivedData-Catalyst/Build/Products/$CONFIG-maccatalyst/Signal.app"
rm -rf "$APP/Contents/PlugIns"
# Catalyst quits an app without multi-window support when its last window closes. Signal should
# keep running to receive messages, so declare support (the patch keeps it to one window).
/usr/libexec/PlistBuddy -c "Set :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes true" "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements "$ROOT/Config/Signal-Catalyst.entitlements" "$APP"

echo "Built $APP"

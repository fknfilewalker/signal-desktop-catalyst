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
# Targets that link a workspace package (blurhash) look for its product under the project's
# default SDK (iphoneos) instead of the Catalyst products directory it's built into.
ln -sfn "$CONFIG-maccatalyst" "$ROOT/build/DerivedData-Catalyst/Build/Products/$CONFIG-iphoneos"

cd "$ROOT/Signal-iOS"
# RingRTC's Swift sources (in Signal's Pods checkout) use an iPad camera API that the Catalyst SDK
# marks unavailable. Guard it, unless an earlier build already did.
git -C Pods apply --reverse --check "$ROOT/patches/ringrtc-catalyst.patch" 2>/dev/null ||
  git -C Pods apply "$ROOT/patches/ringrtc-catalyst.patch"
# libsignal and libmobilecoin come from Swift packages as XCFrameworks with only iOS slices.
# Resolve the packages, then give each XCFramework a Catalyst slice: the library built by
# build-catalyst-deps.sh, next to the iOS slice's headers.
xcodebuild -resolvePackageDependencies -workspace Signal.xcworkspace -scheme Signal \
  -derivedDataPath "$ROOT/build/DerivedData-Catalyst" >/dev/null
ARTIFACTS="$ROOT/build/DerivedData-Catalyst/SourcePackages/artifacts"
add_catalyst_slice() { # xcframework library
  local slice="$1/ios-arm64-maccatalyst" lib
  lib="$(basename "$2")"
  rm -rf "$slice"
  cp -R "$1/ios-arm64" "$slice"
  cp "$2" "$slice/$lib"
  if ! grep -q ios-arm64-maccatalyst "$1/Info.plist"; then
    local headers=""
    [ -d "$slice/Headers" ] && headers='"HeadersPath": "Headers",'
    plutil -insert AvailableLibraries.0 -json "{\"LibraryIdentifier\": \"ios-arm64-maccatalyst\",
      \"LibraryPath\": \"$lib\", \"BinaryPath\": \"$lib\", $headers
      \"SupportedArchitectures\": [\"arm64\"], \"SupportedPlatform\": \"ios\",
      \"SupportedPlatformVariant\": \"maccatalyst\"}" "$1/Info.plist"
  fi
}
add_catalyst_slice "$ARTIFACTS/binarydependencies/LibSignalFfi/LibSignalFfi.xcframework" \
  "$DEPS/libsignal/target/aarch64-apple-ios-macabi/release/libsignal_ffi.a"
add_catalyst_slice "$ARTIFACTS/mobilecoin-swift/LibMobileCoin/LibMobileCoin.xcframework" \
  "$DEPS/libmobilecoin/libmobilecoin/target/aarch64-apple-ios-macabi/mobile-release/libmobilecoin.a"

# No -destination: xcodebuild checks destinations against the project file, which doesn't enable
# Catalyst. The macOS SDK with the iosmac variant selects Mac Catalyst without editing it.
# Xcode 27.1 applies the scheme's test coverage setting to builds too; Swift packages then fail to
# link (undefined ___llvm_profile_runtime), so turn it off. (-enableCodeCoverage only works for tests.)
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
  CLANG_COVERAGE_MAPPING=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
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

#!/bin/bash
# Builds Signal-iOS's native dependencies for Mac Catalyst (arm64). Signal only ships them for
# iPhone/iPad, so they're compiled from source at the versions Signal-iOS pins:
#
#   libsignal     (Rust)          -> build/deps/libsignal/.../libsignal_ffi.a
#   RingRTC       (Rust)          -> build/deps/ringrtc/out/.../libringrtc.a
#   WebRTC        (C++, Chromium) -> build/deps/webrtc-catalyst/WebRTC.framework
#   libmobilecoin (Rust)          -> build/deps/libmobilecoin/.../libmobilecoin.a
#
# Needs: rustup, protoc, cmake, coreutils (grealpath), ~20 GB of disk for WebRTC.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
TARGET=aarch64-apple-ios-macabi
mkdir -p "$DEPS"

if ! command -v cargo >/dev/null && [ -d "$(brew --prefix rustup 2>/dev/null)/bin" ]; then
  export PATH="$(brew --prefix rustup)/bin:$PATH"
fi

# Versions pinned by Signal-iOS (Podfile / Podfile.lock).
LIBSIGNAL_TAG=v0.103.1
RINGRTC_TAG=v2.72.0
# Signal's LibMobileCoin 6.0.2 artifacts have no public source tag; v6.1.0's C API is identical.
LIBMOBILECOIN_TAG=v6.1.0

clone() { # url tag dir
  [ -d "$3/.git" ] || git clone --depth 1 --branch "$2" "$1" "$3"
}

# --- libsignal ---------------------------------------------------------------------------------
clone https://github.com/signalapp/libsignal.git "$LIBSIGNAL_TAG" "$DEPS/libsignal"
rustup target add "$TARGET" --toolchain "$(cat "$DEPS/libsignal/rust-toolchain")"
# boring-sys has no CMake settings for Catalyst (app bundles must be off for iOS-family targets),
# so build with a local copy that adds them. Cargo picks the patch up from build/deps/.cargo.
if [ ! -d "$DEPS/boring" ]; then
  git clone --depth 1 --recurse-submodules --shallow-submodules --branch signal-v5.2.0 https://github.com/signalapp/boring.git "$DEPS/boring"
  git -C "$DEPS/boring" apply "$ROOT/patches/boring-sys-catalyst.patch"
fi
mkdir -p "$DEPS/.cargo"
cp "$ROOT/patches/cargo-config.toml" "$DEPS/.cargo/config.toml"
(cd "$DEPS/libsignal" && MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_BUILD_TARGET=$TARGET swift/build_ffi.sh --release)

# --- WebRTC + RingRTC --------------------------------------------------------------------------
clone https://github.com/signalapp/ringrtc.git "$RINGRTC_TAG" "$DEPS/ringrtc"
[ -d "$DEPS/depot_tools" ] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPS/depot_tools"
export PATH="$DEPS/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
[ -d "$DEPS/ringrtc/src/webrtc/src/tools_webrtc" ] || (cd "$DEPS/ringrtc" && bin/prepare-workspace ios)
WEBRTC_SRC="$DEPS/ringrtc/src/webrtc/src"
# Same GN args as RingRTC's bin/build-ios, for the Catalyst environment. use_lld=false: Chromium's
# bundled lld can't read the newest macOS SDK's .tbd stubs, so link with Apple's ld.
(cd "$WEBRTC_SRC" && ./tools_webrtc/ios/build_ios_libs.py -o out/catalyst --build_config release \
  --arch catalyst:arm64 --deployment-target 14.0 \
  --extra-gn-args "rtc_build_examples=false rtc_build_tools=false rtc_include_tests=false rtc_enable_protobuf=false rtc_enable_sctp=false rtc_libvpx_build_vp9=true rtc_disable_metrics=true rtc_disable_trace_events=true rtc_opus_support_dred=true use_lld=false")
rm -rf "$DEPS/webrtc-catalyst" && mkdir -p "$DEPS/webrtc-catalyst"
cp -R "$WEBRTC_SRC/out/catalyst/WebRTC.xcframework/ios-arm64-maccatalyst/WebRTC.framework" "$DEPS/webrtc-catalyst/"

[ -f "$DEPS/ringrtc/rust-toolchain" ] && rustup target add "$TARGET" --toolchain "$(cat "$DEPS/ringrtc/rust-toolchain")"
(cd "$DEPS/ringrtc/src/rust" && CARGO_TARGET_DIR="$DEPS/ringrtc/out/build" cargo rustc --target $TARGET --release --crate-type staticlib)
mkdir -p "$DEPS/ringrtc/out/release/libringrtc/$TARGET"
cp "$DEPS/ringrtc/out/build/$TARGET/release/libringrtc.a" "$DEPS/ringrtc/out/release/libringrtc/$TARGET/"

# --- libmobilecoin -----------------------------------------------------------------------------
clone https://github.com/mobilecoinofficial/libmobilecoin.git "$LIBMOBILECOIN_TAG" "$DEPS/libmobilecoin"
MC_VENDOR="$DEPS/libmobilecoin/Vendor/mobilecoin"
if [ ! -d "$MC_VENDOR/.git" ]; then
  mkdir -p "$MC_VENDOR"
  git -C "$MC_VENDOR" init -q
  git -C "$MC_VENDOR" fetch -q --depth 1 https://github.com/mobilecoinofficial/mobilecoin.git "$(cat "$DEPS/libmobilecoin/Vendor/mobilecoin.rev")"
  git -C "$MC_VENDOR" checkout -q FETCH_HEAD
fi
MC_TOOLCHAIN="$(cat "$DEPS/libmobilecoin/libmobilecoin/rust-toolchain")"
rustup toolchain install "$MC_TOOLCHAIN" --profile minimal -c rust-src
# The cmake crate MobileCoin locks (0.1.49) passes CMAKE_OSX_SYSROOT=/ for iOS-family targets,
# which CMake rejects. MobileCoin's own fix patches the system CMake; instead use a private
# CMake 3.x in a virtualenv with that check relaxed.
if [ ! -x "$DEPS/cmake-venv/bin/cmake" ]; then
  python3 -m venv "$DEPS/cmake-venv"
  "$DEPS/cmake-venv/bin/pip" install -q "cmake<4"
  sed -i '' '/FATAL_ERROR/ s/^#*/#/' "$(find "$DEPS/cmake-venv" -name iOS-Initialize.cmake | head -1)"
fi
# Catalyst was a tier 3 Rust target in that nightly, hence -Zbuild-std.
(cd "$DEPS/libmobilecoin/libmobilecoin" && PATH="$DEPS/cmake-venv/bin:$PATH" SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" SGX_MODE=HW IAS_MODE=PROD CMAKE_POLICY_VERSION_MINIMUM=3.5 IPHONEOS_DEPLOYMENT_TARGET=14.0 \
  cargo "+$MC_TOOLCHAIN" build --package libmobilecoin --target $TARGET --lib -Z avoid-dev-deps \
  -Z unstable-options --profile mobile-release -Zbuild-std)

echo "Catalyst dependencies are in $DEPS"

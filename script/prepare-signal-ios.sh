#!/bin/bash
# Fetches Signal-iOS's dependencies. The submodule itself is never modified; build settings and
# entitlements for the Mac build live in this repo (Config/) and are passed to xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/Signal-iOS"

git -C "$ROOT" submodule update --init --depth 1 Signal-iOS

# Signal's own setup: Pods submodule, backup test vectors and the prebuilt RingRTC/WebRTC.
if [ ! -f "$IOS/Pods/SignalRingRTC/out/release/libringrtc/aarch64-apple-ios/libringrtc.a" ]; then
  make -C "$IOS" dependencies
fi

echo "Signal-iOS is ready. Next: script/build-catalyst-deps.sh (once), then script/build-catalyst.sh"

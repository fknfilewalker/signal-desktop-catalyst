# Signal for Mac (from Signal-iOS)

Builds the official [Signal-iOS](https://github.com/signalapp/Signal-iOS) app, included here as a
git submodule, as a native **Mac Catalyst** app for Apple silicon Macs.

> Unofficial. Not affiliated with or endorsed by Signal Messenger, LLC.

## Requirements

- Apple silicon Mac, Xcode 26+
- rustup, protoc, cmake, coreutils and Python 3.10+: `brew install rustup protobuf cmake coreutils python`
- About 20 GB of free disk space for the WebRTC checkout

## Build

A fresh install, in order:

```sh
# 1. Tools (once). Xcode 26 itself comes from the App Store.
brew install rustup protobuf cmake coreutils python
rustup-init -y

# 2. Get the code
git clone --recursive https://github.com/fknfilewalker/signal-desktop-catalyst.git
cd signal-desktop-catalyst

# 3. Native libraries for Catalyst: libsignal, WebRTC, RingRTC, libmobilecoin (once, slow)
script/build-catalyst-deps.sh

# 4. The Mac changes to Signal-iOS
git -C Signal-iOS apply ../patches/signal-ios-catalyst.patch

# 5. Build the app (signed ad hoc: no Apple account needed)
script/build-catalyst.sh

# 6. Run it, then link it from your phone: Settings → Linked devices → Link new device
open "build/DerivedData-Catalyst/Build/Products/App Store Release-maccatalyst/Signal.app"
```

Steps 3 and 4 only run once. To update the app after changing something, run step 5 again.

`build-catalyst.sh` builds the "App Store Release" configuration. Set `CONFIGURATION=Debug` for a
debug build. Its developer checks stop the app on unexpected data, which release builds log and
skip.

## How it works

Signal only ships its native dependencies for iPhone and iPad. `build-catalyst-deps.sh` compiles
them for `aarch64-apple-ios-macabi`, at the versions Signal-iOS pins (read from its
`BinaryDependencies/Package.swift`):

| Library | Source | Notes |
| --- | --- | --- |
| libsignal | Rust | boring-sys gets Catalyst CMake settings (`patches/boring-sys-catalyst.patch`) |
| RingRTC | Rust | its Swift sources get a guard for an iPad-only camera API (`patches/ringrtc-catalyst.patch`) |
| WebRTC | C++ (Chromium tooling) | linked with Apple's `ld`; the bundled lld can't read the newest SDK |
| libmobilecoin | Rust | built from v6.1.0, which has the same C API as Signal's 6.0.2 artifacts |

`build-catalyst.sh` runs `xcodebuild` on the unmodified Signal workspace. After resolving Signal's
Swift packages, it adds a Catalyst slice to the libsignal, libmobilecoin, RingRTC and WebRTC
XCFrameworks they download. `Config/Catalyst.xcconfig` holds the Catalyst build settings, and
`Config/CatalystStubs` stands in for an iOS-only framework the project links. `Config/Signal-Catalyst.entitlements` replaces Signal's entitlements.

**Signing:** the app is signed ad hoc, so building needs no Apple developer account and the build
doesn't expire (free-account provisioning profiles do, after 7 days). That works because the
patch drops the two entitlements that need a provisioning profile: Signal's app group (its data
lives in the app's own container instead; the share and notification extensions that would share
it are left out) and its keychain access group (it uses the login keychain: in Catalyst apps the
`SecItem` API only reaches the data protection keychain, which needs that entitlement, so the patch
stores Signal's database key with the older `SecKeychain` functions instead). Rebuilding changes
the ad-hoc signature, so macOS may ask once for Keychain access after a rebuild.

**The app sandbox is required.** Without it, Signal's "Library" and "Documents" folders are your
real `~/Library` and `~/Documents`, and its migrations and cleanup jobs delete files there.

`patches/signal-ios-catalyst.patch` holds the small source changes Signal needs to compile for
Catalyst. On Mac, Wi-Fi Aware and DeviceDiscoveryUI aren't available (device transfer falls back
to Multipeer Connectivity), and the camera multitasking settings are skipped. It also covers the
Apple Pay sheet's window, `QLPreviewController.canPreview`, `contactAccessPicker` and
`NSFileProviderError`. Linking skips the APNs token: macOS refuses it for this build, and a
release build would otherwise fail with "an unknown error" after scanning the QR code. The Mac
then links as a manual message fetcher, like a device without push.

## Limitations

- **No push notifications:** they only work with Signal's production signing, so messages arrive
  while the app is running.
- **Separate install:** a build with your own bundle ID is separate from any official Signal app.
  Link it to your phone as a secondary device.

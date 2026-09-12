# Development notes

## Build and layout

Broschy uses Swift Package Manager, SwiftUI for views, and AppKit for a borderless panel aligned with the screen's safe area. The main executable is `Broschy`; `broschy-cli` writes local command-result records. The package targets macOS 14, while compiling native Liquid Glass support requires the macOS 26 SDK from Xcode 26 or later.

```text
Sources/Broschy/        App, panel behavior, views, storage, Spotify
Sources/BroschyCLI/     Command wrapper and explicit result notifications
Tests/                 Isolated core/CLI/store checks and Spotify fixtures
Resources/             App icon and macOS ICNS bundle
build.sh               Assemble and locally sign the app
test.sh                Run both test executables in a temporary directory
```

`bash build.sh` uses `.build/` by default. Set `BROSCHY_BUILD_CACHE` to put the Swift build cache elsewhere. `NOTCHFLOW_BUILD_CACHE` remains accepted for older local scripts. Build output is always under `build/` and is ignored by Git.

The app is signed ad hoc, not with a Developer ID certificate, and is not notarized. Signing and distribution credentials are not part of this repository. The build uses the host architecture; the current CI runner is Apple Silicon.

## Compatibility with NotchFlow

Broschy was previously named NotchFlow. The package, binaries, app bundle name, icon, menus, and CLI branding have changed. Two internal identifiers intentionally have not:

- `pl.local.NotchFlow` is the macOS bundle identifier, keeping the same preferences domain and application identity for Automation.
- `~/Library/Application Support/NotchFlow/` is the existing storage folder used by both the app and CLI.

Do not rename those strings mechanically. That would split existing data and system permissions. No migration or data deletion is needed for the Broschy rename. Quit the previous app before launching Broschy; both names represent the same application identity.

## Spotify behavior

The app sends native Apple Events to the running Spotify process after an explicit connection. Requests run serially off the main thread. Controls are ordered, disconnect invalidates stale responses, and routine polling does not prompt again for permission.

Track fields are read individually: Spotify can reject aggregate property reads with error `-10000` because its legacy `starred` field is unavailable. Missing optional metadata does not disable playback controls. Album images are fetched from validated HTTPS artwork hosts returned by Spotify.

## Verification

`bash test.sh` checks timer deadlines and sleep, pause/resume, persisted state and recovery, CLI exit status and cancellation, metadata normalization, Apple Event encoding, error handling, request ordering, and stale response rejection. It uses separate temporary directories and mocked Spotify responses.

GitHub Actions runs those checks, builds the release bundle, validates its property list, verifies the local signature, and exercises the CLI help path on a macOS 26 runner. It does not test a physical notch or connect to Spotify.

Manual checks on macOS 26 / Apple Silicon have covered compact and expanded layouts, light/dark appearance in an isolated preview window, reduced motion/transparency, real Spotify metadata and artwork, and play/pause. Next/previous and seeking have encoding checks; they have not been exercised as part of the documented live-player check. No Instruments FPS measurement or older-macOS device run is claimed.

## Before changing panel behavior

Check hover and keyboard activation, quick open/close reversals, the camera gap, text entry, pinning, and the fallback layout without a physical notch. Keep the temporarily expanded drawing canvas used during the close animation. Playback bars must stop animating when paused, hidden, or Reduce Motion is active.

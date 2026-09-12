# Development notes

## Build and layout

Broschy uses Swift Package Manager, SwiftUI for views, and AppKit for a borderless panel aligned with the screen's safe area. The main executable is `Broschy`; `broschy-cli` writes local command-result records. The package targets macOS 14, while compiling native Liquid Glass support requires the macOS 26 SDK from Xcode 26 or later.

```text
Sources/Broschy/        App, panel, preferences, storage, Spotify, Build Watch
Sources/BroschyCLI/     Command wrapper, result notifications, agent hook entry point
Sources/AgentBridge/    Normalized agent sessions, process identity, atomic snapshots
Integrations/opencode/ Metadata-only OpenCode event adapter
scripts/               Reversible agent configuration installer
Tests/                 Core, agents, installer, preferences, priority, integration mocks
Resources/             App icon and macOS ICNS bundle
build.sh               Assemble and locally sign the app
test.sh                Run Swift and Python/Node checks with isolated data
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

## Agent activity

The bridge stores the last observed event, while `effectiveStatus` derives the current display state. Hook capture walks a bounded ancestor chain and records only the originating provider process ID, start time, and executable name. Checking that exact identity avoids confusing another terminal session, a reused PID, or the shared desktop app-server with the original process.

An exited process closes active sessions immediately without relying on an exit hook. Unverified activity expires after 75 seconds; verified-live working activity expires after 120 seconds; verified-live waiting requests expire after 30 minutes. Expiry means unknown, never success. Ready responses and errors remain reviewable after process exit. Metadata-only updates do not refresh activity freshness.

Codex CLI 0.144.5 does not dispatch SessionEnd/Interrupt hooks. Keep process checks and age limits even when newer provider versions expose more events. Existing snapshots without process identity remain readable and use the unverified fallback. See [Agents](AGENTS.md) for installation and privacy details.

## Layout and Quiet Focus

`PanelTab` preserves existing IDs (`Focus = 0`, `Signals = 1`, `Later = 2`, `Music = 3`, `Agents = 4`) while displaying visible tabs in Agents, Focus, Music, Signals, Later order. `PanelPreferences` stores only the visibility set and Quiet Focus flag in the existing UserDefaults domain. It sanitizes invalid saved values, prevents an empty layout, and supplies a safe visible selection when a tab is hidden. Reset removes only these two preference keys.

All modules are visible and Quiet Focus is off by default. The compact selector filters hidden modules before choosing an activity or its click destination. Hiding a module changes presentation without stopping background work. Settings are available through the header gear, the menu bar's **Settings…** item, and Command-comma.

Quiet Focus uses `timer.isRunning`; a paused countdown releases its suppression. `AgentAttentionPolicy` keeps active questions and permissions eligible to interrupt while holding response/error review items in the full Agents queue. An error with a pending request must also pass the request's process-liveness and freshness checks. Local command and Build Watch results defer to the running focus timer. Ending or pausing Focus restores normal priority, subject to each result's existing expiry. This policy does not alter macOS Focus or other apps' notifications.

## Build Watch

`BuildWatchController` manages one opt-in GitHub.com target in **Signals → Build Watch**. **Signals → Commands** retains the local CLI integration. Targets accept a repository with its default or specified branch, or a pull request. Repository queries filter by branch; PR queries resolve the current head SHA before reading workflow runs. A changed PR head creates a fresh baseline.

The transport runs installed `gh api` with explicit GET requests to GitHub.com. GitHub CLI handles the existing authentication; Broschy does not extract or store tokens. It looks for `gh` in common Homebrew locations and absolute PATH entries, disables interactive prompts, and keeps network work off the main thread. Each poll shares a 15-second deadline across its requests; each response is bounded to 1 MiB of stdout and 8 KiB of diagnostics. Diagnostics are classified into generic errors and are not surfaced or logged verbatim.

Successful polls schedule the next read after 30 seconds. Failures back off to 60, 120, then 300 seconds, clear live activity and the compact completion, and retain the last rows as stale context. Data older than 75 seconds stops contributing a live running indicator. Disconnect and target changes invalidate in-flight responses.

The panel keeps up to ten runs. A 12-second compact result requires observing a run active and then completed within the same target/branch or PR-head scope. Initial completed runs remain silent. Run ID plus attempt distinguishes reruns; a bounded set of 30 completion identifiers prevents repeat announcements. The target, enabled flag, and these identifiers persist in UserDefaults. Fetched workflow metadata remains in memory. The integration does not download full logs or perform workflow, repository, or pull-request mutations.

## Verification

`bash test.sh` checks timer deadlines and sleep, pause/resume, persisted state and recovery, CLI exit status and cancellation, metadata normalization, Apple Event encoding, error handling, request ordering, and stale response rejection. It uses separate temporary directories and mocked Spotify responses. Agent checks cover redaction, concurrent requests, stale acknowledgments, process exit without a terminal event, PID reuse, activity expiry, and provider-specific event normalization. Installer tests preserve existing configuration; Node checks exercise the OpenCode plugin without model requests. Mocked Build Watch checks cover target parsing, response validation, polling, stale replies, and completion handling. Preference and priority checks cover relaunch, malformed values, the final visible tab, Quiet Focus, hidden modules, and compact destinations. These checks do not establish live GitHub account access.

GitHub Actions runs those checks, builds the release bundle, validates its property list, verifies the local signature, and exercises the CLI help path on a macOS 26 runner. It does not test a physical notch or connect to Spotify.

Manual checks on macOS 26 / Apple Silicon have covered compact and expanded layouts, light/dark appearance in an isolated preview window, reduced motion/transparency, real Spotify metadata and artwork, and play/pause. Build Watch has also fetched live results from the public Broschy repository using the default branch. UI checks covered hiding the selected tab, last-tab protection, restoring the layout, compact music fallback, and light/dark workflow rows. The live check did not dispatch a new workflow. Next/previous and seeking have encoding checks; they have not been exercised as part of the documented live-player check. No Instruments FPS measurement or older-macOS device run is claimed.

## Before changing panel behavior

Check hover and keyboard activation, quick open/close reversals, the camera gap, text entry, pinning, Settings, hidden-tab selection, compact click destinations, and the fallback layout without a physical notch. Keep the temporarily expanded drawing canvas used during the close animation. Playback bars must stop animating when paused, hidden, or Reduce Motion is active.

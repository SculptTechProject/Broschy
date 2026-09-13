# Development notes

## Build and layout

Broschy uses Swift Package Manager, SwiftUI for views, and AppKit for a borderless panel aligned with the screen's safe area. The main executable is `Broschy`; `broschy-cli` writes local command-result records. The package targets macOS 14, while compiling native Liquid Glass support requires the macOS 26 SDK from Xcode 26 or later.

`StatusBarIcon.makeImage()` draws the 18-point menu bar mark as a native vector template. `isTemplate` lets macOS handle light, dark, and selected appearances; the icon has a Broschy accessibility description and tooltip.

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

`PanelGeometry` is shared by panel sizing and native window placement. The resting compact height is the screen's positive top safe-area inset, falling back to `NSStatusBar.system.thickness` on displays without a notch. No extra 8-point lip extends below that band. Frame calculations retain the screen's top anchor and clamp the window horizontally to the chosen display. Compact width leaves 12 points of room below the expanded panel width so the hover preview can grow within that limit.

Hover first grows the visible surface by 12 points in total width and 4 points in height with a 140 ms ease-out, then opens after 220 ms of pointer intent. Opening uses a spring with response `0.34`, damping fraction `0.88`, and blend duration `0.08`; the measured camera region remains fixed. Explicit clicks and keyboard actions call opening directly without the hover delay. Passive hover does not take keyboard focus. Leaving a preview shrinks it; leaving an expanded panel allows 450 ms before closing, subject to pinning, open popovers, and keyboard focus.

Closing uses a restrained spring with response `0.26`, damping fraction `0.88`, and blend duration `0.08`. The enlarged native canvas remains for 360 ms while the glass settles. Explicit dismissal under the pointer suppresses reopening until a real pointer exit; synthetic tracking events from resizing or releasing focus do not cancel that suppression. Hover and transition generation counters invalidate pending callbacks on reversals, screen changes, and accessibility changes so an old close cannot shrink a reopened panel. Reduce Motion skips preview growth and opening/closing animation while retaining the hover intent delay. Compact Music, Agents, and Build Watch receive the actual surface height; below 28 points they show one text line, with secondary text returning at 28 points or above. Music also omits its compact progress strip below that threshold.

`PanelTab` preserves existing IDs (`Focus = 0`, `Signals = 1`, `Later = 2`, `Music = 3`, `Agents = 4`) while displaying visible tabs in Agents, Focus, Music, Signals, Later order. `PanelPreferences` stores only the visibility set and Quiet Focus flag in the existing UserDefaults domain. It sanitizes invalid saved values, prevents an empty layout, and supplies a safe visible selection when a tab is hidden. Reset removes only these two preference keys.

All modules are visible and Quiet Focus is off by default. The compact selector filters hidden modules before choosing an activity or its click destination. Hiding a module changes presentation without stopping background work. Settings are available through the header gear, the menu bar's **Settings…** item, and Command-comma.

`AgentAttentionPolicy` reserves **Needs you** for fresh, actionable questions and permissions. Stopped responses stay in **Ready to review** and never contribute compact attention; readiness is not proof of task success. Unreviewed failures stay in **Errors** and use a separate red compact indication. A pending request attached to an error must pass the request's process-liveness and freshness checks before it can interrupt as a request.

Quiet Focus uses `timer.isRunning`; a paused countdown releases its suppression. Fresh questions and permissions remain eligible to interrupt, while error, working-agent, local command result, and Build Watch result indicators defer to the running focus timer. Ready responses remain panel-only regardless of Quiet Focus. Ending or pausing Focus restores normal priority, subject to each result's existing expiry. This policy does not alter macOS Focus or other apps' notifications.

## Build Watch

`BuildWatchMonitor` manages the opt-in watchlist in **Signals → Build Watch**, with a separate `BuildWatchController` for each target. **Signals → Commands** retains the local CLI integration. Targets accept a repository with its default or specified branch, or a pull request. Repository queries filter by branch; PR queries resolve the current head SHA before reading workflow runs. A changed PR head creates a fresh baseline.

The transport runs installed `gh api` with explicit GET requests to GitHub.com. GitHub CLI handles the existing authentication; Broschy does not extract or store tokens. It looks for `gh` in common Homebrew locations and absolute PATH entries, disables interactive prompts, and keeps network work off the main thread. Each poll shares a 15-second deadline across its requests; each response is bounded to 1 MiB of stdout and 8 KiB of diagnostics. Diagnostics are classified into generic errors and are not surfaced or logged verbatim.

Successful polls schedule the next read after 30 seconds. Failures back off to 60, 120, then 300 seconds, clear live activity and the compact completion, and retain the last rows as stale context. Data older than 75 seconds stops contributing a live running indicator. Removing or editing a target invalidates its in-flight responses without affecting other targets. Each controller owns its polling, cancellation, freshness, and retry schedule.

The panel keeps up to ten runs per target. A 12-second compact result requires observing a run active and then completed within the same target/branch or PR-head scope. Initial completed runs remain silent. Run ID plus attempt distinguishes reruns; a bounded set of 30 completion identifiers prevents repeat announcements. A UUID watchlist and namespaced target, enabled flag, and completion identifiers persist in UserDefaults. The monitor migrates the previous enabled single target and its completion history once; a disabled legacy target is not enabled, and an empty saved watchlist remains empty. Duplicate detection compares owner/repository without case sensitivity and preserves the exact branch or PR scope. Aggregate compact activity excludes stale controllers, prioritizes the latest eligible completion, and otherwise shows an active build. Fetched workflow metadata remains in memory. The integration does not download full logs or perform workflow, repository, or pull-request mutations.

## Release payload privacy

`build.sh` assembles a fresh bundle from an explicit set of resources, strips SwiftPM STABS debug records with `strip -S`, then signs the CLI and app. These records can contain absolute source and object-file paths even in optimized release binaries. Runtime symbols remain; unstripped build products and debug information stay outside the published app.

`scripts/check-bundle-privacy.py` checks the finished bundle before replacing the local output. It rejects undeclared files/directories, symlinks, missing resources, common home/temporary path roots, and selected credential patterns. It scans raw bytes, including Mach-O string tables that the system `strings` tool can omit. Diagnostics identify only declared files and categories, without printing matched values. The same gate runs in CI through `build.sh`; it complements, rather than replaces, source/history secret scanning and review of documentation and images.

## Verification

`bash test.sh` checks timer deadlines and sleep, pause/resume, persisted state and recovery, CLI exit status and cancellation, metadata normalization, Apple Event encoding, error handling, request ordering, and stale response rejection. It uses separate temporary directories and mocked Spotify responses. Agent checks cover redaction, concurrent requests, stale acknowledgments, process exit without a terminal event, PID reuse, activity expiry, and provider-specific event normalization. Installer tests preserve existing configuration; Node checks exercise the OpenCode plugin without model requests. Mocked Build Watch checks cover target parsing, response validation, polling, stale replies, completion handling, watchlist migration and persistence, duplicate scopes, and independent controllers. Preference and priority checks cover relaunch, malformed values, the final visible tab, Quiet Focus, hidden modules, and compact destinations. These checks do not establish live GitHub account access.

`PanelGeometryTests` runs through the same test script. It checks resting menu-band fit with 22-, 24-, and 38-point inputs, compact and preview width limits, the 4-point preview growth, stable top anchoring, horizontal clamping, displays with offset or negative origins, and animation-canvas clearance. These geometry assertions do not measure rendered animation smoothness or replace physical-notch checks.

GitHub Actions runs those checks, builds the release bundle, validates its property list, verifies the local signature, and exercises the CLI help path on a macOS 26 runner. It does not test a physical notch or connect to Spotify.

Manual checks on macOS 26 / Apple Silicon have covered compact and expanded layouts, light/dark appearance in an isolated preview window, reduced motion/transparency, real Spotify metadata and artwork, and play/pause. Build Watch has also fetched live results from the public Broschy repository using the default branch. UI checks covered hiding the selected tab, last-tab protection, restoring the layout, compact music fallback, and light/dark workflow rows. The live check did not dispatch a new workflow. Next/previous and seeking have encoding checks; they have not been exercised as part of the documented live-player check. No Instruments FPS measurement or older-macOS device run is claimed.

Native previews with isolated preferences and mocked responses also cover the multi-repository list, independent connection errors, long names, scrolling, add/edit/remove, duplicate validation, PR branch handling, and light/dark appearance. The existing Broschy watch was verified after migration in the local app. Separate scratch lifecycle checks exercise normal and Reduce Motion opening/closing, synthetic tracking callbacks, genuine pointer exit/reentry, and deferred compact-width changes during dismissal; they use deterministic mouse positions and do not measure physical hover delivery or spring smoothness.

## Before changing panel behavior

Check hover and keyboard activation, quick open/close reversals, the camera gap, text entry, pinning, Settings, hidden-tab selection, compact click destinations, and the fallback layout without a physical notch. Keep the temporarily expanded drawing canvas used during the close animation. Playback bars must stop animating when paused, hidden, or Reduce Motion is active.

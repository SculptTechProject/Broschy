# Contributing to Broschy

Thanks for helping make a useful little corner of macOS.

## Start locally

Use a Mac with Xcode 26 or later. Clone the repository, run `bash test.sh`, then `bash build.sh` and `open build/Broschy.app`. There are no third-party Swift dependencies to install.

## Report an issue

Include your macOS version, Mac model, Broschy version, and the steps that reproduce the problem. For layout issues, mention external displays, full-screen mode, Stage Manager, and whether the menu bar hides automatically. Screenshots help; remove personal notes, command paths, or music details you do not want to share.

## Send a change

Keep a pull request focused on one problem and describe the resulting behavior. Include the checks you ran and screenshots for visual changes. Preserve the single glass surface, English UI copy, keyboard controls, and both accessibility preferences.

Run `bash test.sh` and `bash build.sh` before opening a pull request. Add a regression check when fixing behavior that can be verified reliably. For visual changes, check Light, Dark, Reduce Motion, Reduce Transparency, and both compact and expanded layouts.

Spotify's automated tests use mocked responses. Do not add tests that launch a real player, request system permissions, or depend on a contributor's account.

Do not commit build output, local state, tokens, signing certificates, or personal screenshots. The existing bundle identifier and storage path are intentional compatibility contracts; changes to either need a migration plan.

Release builds assemble a fresh bundle, remove source-path debug records before signing, and check the public payload with `scripts/check-bundle-privacy.py`. Keep that gate passing; review documentation, screenshot metadata, and commit history separately before publishing.

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/broschy-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -D BROSCHY_TESTS -D FLOW_STORE_TESTS Sources/Broschy/Core.swift Sources/Broschy/Store.swift Sources/BroschyCLI/main.swift Tests/BroschyCoreTests.swift -o "$test_dir/checks"
"$test_dir/checks" "$test_dir"
swiftc -swift-version 5 -D SPOTIFY_TESTS -parse-as-library Sources/Broschy/SpotifyController.swift Tests/SpotifyControllerTests.swift -o "$test_dir/spotify-checks"
"$test_dir/spotify-checks"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/broschy-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -emit-library -emit-module -module-name AgentBridge Sources/AgentBridge/*.swift -emit-module-path "$test_dir/AgentBridge.swiftmodule" -o "$test_dir/libAgentBridge.dylib"
swiftc -D BROSCHY_TESTS -D FLOW_STORE_TESTS -I "$test_dir" -L "$test_dir" -lAgentBridge -Xlinker -rpath -Xlinker "$test_dir" Sources/Broschy/Core.swift Sources/Broschy/Store.swift Sources/BroschyCLI/*.swift Tests/BroschyCoreTests.swift -o "$test_dir/checks"
"$test_dir/checks" "$test_dir"
swiftc -swift-version 5 -D SPOTIFY_TESTS -parse-as-library Sources/Broschy/SpotifyController.swift Tests/SpotifyControllerTests.swift -o "$test_dir/spotify-checks"
"$test_dir/spotify-checks"
swiftc -swift-version 5 -parse-as-library -I "$test_dir" -L "$test_dir" -lAgentBridge -Xlinker -rpath -Xlinker "$test_dir" Sources/BroschyCLI/AgentCommand.swift Tests/AgentBridgeTests.swift -o "$test_dir/agent-checks"
"$test_dir/agent-checks" "$test_dir"
swiftc -swift-version 5 -parse-as-library -I "$test_dir" -L "$test_dir" -lAgentBridge -Xlinker -rpath -Xlinker "$test_dir" Sources/Broschy/PanelPreferences.swift Tests/PanelPreferencesTests.swift -o "$test_dir/preferences-checks"
"$test_dir/preferences-checks"
swiftc -swift-version 5 -parse-as-library -I "$test_dir" -L "$test_dir" -lAgentBridge -Xlinker -rpath -Xlinker "$test_dir" Sources/Broschy/PanelPreferences.swift Sources/Broschy/PanelActivity.swift Tests/PanelActivityTests.swift -o "$test_dir/activity-checks"
"$test_dir/activity-checks"
swiftc -swift-version 5 -parse-as-library Sources/Broschy/PanelGeometry.swift Tests/PanelGeometryTests.swift -o "$test_dir/geometry-checks"
"$test_dir/geometry-checks"
swiftc -swift-version 5 -parse-as-library Sources/Broschy/BuildWatchModels.swift Sources/Broschy/BuildWatchController.swift Tests/BuildWatchTests.swift -o "$test_dir/build-watch-checks"
"$test_dir/build-watch-checks"
swiftc -swift-version 5 -parse-as-library Sources/Broschy/BuildWatchModels.swift Sources/Broschy/BuildWatchController.swift Sources/Broschy/BuildWatchMonitor.swift Tests/BuildWatchMonitorTests.swift -o "$test_dir/build-watch-monitor-checks"
"$test_dir/build-watch-monitor-checks"
python3 Tests/test_agent_integrations.py
python3 Tests/test_bundle_privacy.py

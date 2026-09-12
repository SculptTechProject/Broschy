import AgentBridge
import CoreFoundation
import Foundation

@main
enum PanelPreferencesTests {
    @MainActor
    static func main() {
        let suite = "Broschy.PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let unrelated: [String: Any] = ["spotifyIntegrationEnabled": true, "customPreference": "Keep this"]
        unrelated.forEach { defaults.set($0.value, forKey: $0.key) }
        func checkUnrelated() {
            precondition(defaults.bool(forKey: "spotifyIntegrationEnabled"))
            precondition(defaults.string(forKey: "customPreference") == "Keep this")
        }

        let initial = PanelPreferences(defaults: defaults)
        precondition(initial.visibleTabs == Set(PanelTab.allCases))
        precondition(initial.orderedVisibleTabs == [.agents, .focus, .music, .signals, .later])
        precondition(!initial.quietFocusEnabled, "Existing interruption behavior should remain the default.")
        precondition(defaults.object(forKey: PanelPreferences.visibleTabsKey) == nil,
                     "Loading defaults should not write a redundant preference.")
        precondition(initial.safeSelection(.music) == .music)
        precondition(initial.safeSelection(nil) == .agents)
        precondition(PanelTab.focus.rawValue == 0 && PanelTab.signals.rawValue == 1
                     && PanelTab.later.rawValue == 2 && PanelTab.music.rawValue == 3
                     && PanelTab.agents.rawValue == 4, "Visual ordering must not change existing IDs.")

        precondition(initial.setVisible(false, for: .agents))
        precondition(initial.setVisible(false, for: .music))
        initial.quietFocusEnabled = true
        let restored = PanelPreferences(defaults: defaults)
        precondition(restored.visibleTabs == [.focus, .signals, .later] && restored.quietFocusEnabled)
        precondition(restored.orderedVisibleTabs == [.focus, .signals, .later])
        precondition(restored.safeSelection(.agents) == .focus,
                     "A hidden selected tab must fall back to a visible tab.")
        precondition(restored.setVisible(false, for: .focus))
        precondition(restored.fallbackTab == .signals)
        precondition(restored.setVisible(false, for: .signals))
        let savedLastTab = defaults.array(forKey: PanelPreferences.visibleTabsKey) as? [Int]
        precondition(!restored.setVisible(false, for: .later), "At least one module must remain visible.")
        precondition(restored.visibleTabs == [.later])
        precondition(defaults.array(forKey: PanelPreferences.visibleTabsKey) as? [Int] == savedLastTab)
        precondition(restored.setVisible(true, for: .later), "Setting an unchanged visibility is harmless.")
        precondition(restored.setVisible(true, for: .music))
        precondition(restored.orderedVisibleTabs == [.music, .later])
        checkUnrelated()
        restored.resetDefaults()
        precondition(restored.visibleTabs == Set(PanelTab.allCases) && !restored.quietFocusEnabled)
        precondition(defaults.object(forKey: PanelPreferences.visibleTabsKey) == nil
                     && defaults.object(forKey: PanelPreferences.quietFocusKey) == nil)
        checkUnrelated()

        let invalidValues: [Any] = ["all", true, [Any](), [99, -1], [true, false], ["Music", "0"], [0.5, 3.75]]
        for value in invalidValues {
            defaults.set(value, forKey: PanelPreferences.visibleTabsKey)
            let repaired = PanelPreferences(defaults: defaults)
            precondition(repaired.visibleTabs == Set(PanelTab.allCases), "Invalid or empty visibility must recover to a usable panel.")
            precondition(PanelPreferences(defaults: defaults).visibleTabs == repaired.visibleTabs)
            checkUnrelated()
        }
        defaults.set([3, 3, 99, "bad", true, 0] as [Any], forKey: PanelPreferences.visibleTabsKey)
        let partiallyValid = PanelPreferences(defaults: defaults)
        precondition(partiallyValid.visibleTabs == [.focus, .music], "Keep valid tab IDs while dropping duplicates and malformed values.")
        precondition(defaults.array(forKey: PanelPreferences.visibleTabsKey) as? [Int] == [0, 3])
        for invalidQuiet: Any in ["true", 1, [true]] {
            defaults.set(invalidQuiet, forKey: PanelPreferences.quietFocusKey)
            precondition(!PanelPreferences(defaults: defaults).quietFocusEnabled)
        }
        checkUnrelated()
        print("PASS: stable tab IDs, custom layout persistence, selection fallback, last-tab guard, malformed preference recovery, unrelated settings preserved")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ id: String, _ status: AgentStatus, age: TimeInterval = 0,
                    pending: [String] = [], acknowledged: Bool = false,
                    owner: AgentProcessIdentity? = nil) -> AgentSession {
            AgentSession(provider: .codex, sessionID: id, cwd: "/sample/project", status: status,
                         detail: "Working", updatedAt: now.addingTimeInterval(-age),
                         pendingRequestIDs: pending, acknowledgedAt: acknowledged ? now : nil,
                         ownerProcess: owner)
        }
        let waiting = sample("waiting", .needsAttention, pending: ["permission-1"])
        let ready = sample("ready", .ready)
        let error = sample("error", .error)
        let working = sample("working", .working)
        let reviewed = sample("reviewed", .ready, acknowledged: true)
        let closed = sample("closed", .closed)
        let stale = sample("stale", .needsAttention, age: 76, pending: ["old-permission"])
        let sessions = [ready, waiting, error, working, reviewed, closed, stale]
        let originalSessions = sessions

        let normal = AgentAttentionPolicy.compactAttention(from: sessions, visibleTabs: Set(PanelTab.allCases),
                                                           quietFocusEnabled: false, focusActive: true, now: now)
        precondition(normal.map(\.sessionID) == ["ready", "waiting", "error"])
        let quiet = AgentAttentionPolicy.compactAttention(from: sessions, visibleTabs: Set(PanelTab.allCases),
                                                          quietFocusEnabled: true, focusActive: true, now: now)
        precondition(quiet.map(\.sessionID) == ["waiting"], "Only an active question or permission request should interrupt Quiet Focus.")
        let paused = AgentAttentionPolicy.compactAttention(from: sessions, visibleTabs: Set(PanelTab.allCases),
                                                           quietFocusEnabled: true, focusActive: false, now: now)
        precondition(paused == normal, "Pausing or finishing Focus should reveal queued responses and errors.")
        let hidden = AgentAttentionPolicy.compactAttention(from: sessions, visibleTabs: [.focus, .music],
                                                           quietFocusEnabled: false, focusActive: false, now: now)
        precondition(hidden.isEmpty, "A hidden Agents module must never supply a compact interruption.")
        precondition(sessions == originalSessions && ready.needsAttention(at: now) && error.needsAttention(at: now),
                     "Quiet Focus must not acknowledge or remove items from the full Agents queue.")

        let errorWithRequest = sample("error-request", .error, pending: ["question-1"])
        precondition(AgentAttentionPolicy.requiresInterruption(errorWithRequest, quietFocusEnabled: true,
                                                               focusActive: true, now: now),
                     "A fresh unanswered request accompanying an error still needs a decision.")
        let staleErrorRequest = sample("stale-error-request", .error, age: 76, pending: ["question-2"])
        precondition(!AgentAttentionPolicy.requiresInterruption(staleErrorRequest, quietFocusEnabled: true,
                                                                focusActive: true, now: now))
        precondition(AgentAttentionPolicy.requiresInterruption(staleErrorRequest, quietFocusEnabled: false,
                                                               focusActive: true, now: now),
                     "The error stays available for review after its active request becomes unverified.")
        let owner = AgentProcessIdentity(pid: 123, startedAtSeconds: 1_700_000_000,
                                         startedAtMicroseconds: 0, executableName: "codex")
        let liveErrorRequest = sample("live-error-request", .error, age: 300, pending: ["question-3"], owner: owner)
        precondition(AgentAttentionPolicy.requiresInterruption(liveErrorRequest, quietFocusEnabled: true,
                                                               focusActive: true, now: now, ownerLiveness: .alive))
        precondition(!AgentAttentionPolicy.requiresInterruption(liveErrorRequest, quietFocusEnabled: true,
                                                                focusActive: true, now: now, ownerLiveness: .exited))
        precondition(!AgentAttentionPolicy.requiresInterruption(liveErrorRequest, quietFocusEnabled: true,
                                                                focusActive: true, now: now, ownerLiveness: .unknown))
        let expiredLiveRequest = sample("expired-live-request", .error, age: 1_801, pending: ["question-4"], owner: owner)
        precondition(!AgentAttentionPolicy.requiresInterruption(expiredLiveRequest, quietFocusEnabled: true,
                                                                focusActive: true, now: now, ownerLiveness: .alive))
        precondition(errorWithRequest.status == .error && errorWithRequest.pendingRequestIDs == ["question-1"])
        print("PASS: Quiet Focus interruptions, paused-focus reveal, hidden Agents, unchanged review queue, pending-error request freshness and exact-process liveness")
    }
}

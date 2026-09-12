import AgentBridge
import Foundation

@main
struct PanelActivityTests {
    static func main() {
        func choose(_ tabs: Set<PanelTab> = Set(PanelTab.allCases), quiet: Bool = false,
                    attention: Bool = false, working: Bool = false, focus: Bool = false,
                    local: Bool = false, recent: Bool = false, build: Bool = false,
                    music: Bool = true) -> CompactContent {
            CompactContent.choose(visibleTabs: tabs, quietFocusRunning: quiet,
                agentAttention: attention, workingAgents: working, focusActive: focus,
                localActivity: local, recentBuild: recent, activeBuild: build, musicAvailable: music)
        }
        precondition(choose(attention: true, focus: true, local: true) == .agents)
        precondition(choose(quiet: true, attention: true, focus: true) == .agents)
        precondition(choose(quiet: true, focus: true, local: true, recent: true, build: true) == .focus)
        precondition(choose(focus: true, local: true) == .localSignal)
        precondition(choose(focus: true, recent: true) == .buildWatch)
        precondition(choose(focus: true, build: true) == .focus)
        precondition(choose(working: true, build: true) == .buildWatch)
        precondition(choose(working: true) == .agents)
        precondition(choose() == .music)
        // A completed response stays in Agents without blocking music or an idle notch.
        let now = Date()
        let completed = AgentSession(provider: .codex, sessionID: "finished", cwd: "/sample/project",
                                     status: .ready, updatedAt: now)
        for quiet in [false, true] {
            let attention = AgentAttentionPolicy.compactAttention(from: [completed],
                visibleTabs: Set(PanelTab.allCases), quietFocusEnabled: quiet, focusActive: quiet, now: now)
            precondition(choose(quiet: quiet, attention: !attention.isEmpty) == .music)
            precondition(choose(quiet: quiet, attention: !attention.isEmpty, music: false) == .idle)
        }
        precondition(choose([.later], attention: true, working: true, focus: true,
                            local: true, recent: true, build: true) == .idle)
        precondition(choose([.music], attention: true, focus: true, local: true, recent: true) == .music)
        precondition(choose([.signals], quiet: true, local: true, recent: true, build: true) == .idle)
        precondition(choose([.agents, .music], quiet: true, working: true, focus: true) == .music)
        precondition(choose([.agents], quiet: true, working: true, focus: true) == .idle)
        precondition(choose([.agents, .music], quiet: true, attention: true, working: true, focus: true) == .agents)
        // Pausing Focus releases deferred completions (caller passes quiet=false).
        precondition(choose(quiet: false, focus: true, recent: true) == .buildWatch)
        for content in [CompactContent.agents, .focus, .localSignal, .buildWatch, .music] {
            precondition(content.destination != nil)
        }
        precondition(CompactContent.buildWatch.destination == .signals)
        precondition(CompactContent.localSignal.destination == .signals)
        precondition(CompactContent.idle.destination == nil)
        print("Panel activity priority checks passed")
    }
}

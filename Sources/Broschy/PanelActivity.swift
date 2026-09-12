import Foundation

/// One decision drives the compact content, its width, and its click destination.
enum CompactContent: Equatable {
    case idle, agents, focus, localSignal, buildWatch, music

    var destination: PanelTab? {
        switch self {
        case .idle: return nil
        case .agents: return .agents
        case .focus: return .focus
        case .localSignal, .buildWatch: return .signals
        case .music: return .music
        }
    }

    var usesWideWings: Bool { self == .agents || self == .music || self == .buildWatch }

    static func choose(visibleTabs: Set<PanelTab>, quietFocusRunning: Bool,
                       agentAttention: Bool, workingAgents: Bool, focusActive: Bool,
                       localActivity: Bool, recentBuild: Bool, activeBuild: Bool,
                       musicAvailable: Bool) -> CompactContent {
        if visibleTabs.contains(.agents), agentAttention { return .agents }
        if !quietFocusRunning {
            if visibleTabs.contains(.signals), localActivity { return .localSignal }
            if visibleTabs.contains(.signals), recentBuild { return .buildWatch }
        }
        if visibleTabs.contains(.focus), focusActive { return .focus }
        if !quietFocusRunning, visibleTabs.contains(.signals), activeBuild { return .buildWatch }
        if !quietFocusRunning, visibleTabs.contains(.agents), workingAgents { return .agents }
        if visibleTabs.contains(.music), musicAvailable { return .music }
        return .idle
    }
}

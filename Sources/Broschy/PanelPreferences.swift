import AgentBridge
import Combine
import CoreFoundation
import Foundation

/// IDs stay compatible with the panel's existing selection and launch options.
enum PanelTab: Int, CaseIterable, Identifiable {
    case focus = 0
    case signals = 1
    case later = 2
    case music = 3
    case agents = 4

    var id: Int { rawValue }

    static let displayOrder: [PanelTab] = [.agents, .focus, .music, .signals, .later]

    var displayTitle: String {
        switch self {
        case .focus: return "Focus"
        case .signals: return "Signals"
        case .later: return "Later"
        case .music: return "Music"
        case .agents: return "Agents"
        }
    }

    var systemSymbol: String {
        switch self {
        case .focus: return "scope"
        case .signals: return "terminal"
        case .later: return "text.alignleft"
        case .music: return "music.note"
        case .agents: return "circle.dotted"
        }
    }
}

@MainActor
final class PanelPreferences: ObservableObject {
    static let visibleTabsKey = "broschy.panel.visibleTabs"
    static let quietFocusKey = "broschy.panel.quietFocusEnabled"
    static let defaultVisibleTabs = Set(PanelTab.allCases)

    @Published private(set) var visibleTabs: Set<PanelTab>
    @Published var quietFocusEnabled: Bool {
        didSet {
            guard quietFocusEnabled != oldValue else { return }
            defaults.set(quietFocusEnabled, forKey: Self.quietFocusKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedTabs = defaults.object(forKey: Self.visibleTabsKey)
        let savedQuietFocus = defaults.object(forKey: Self.quietFocusKey)
        visibleTabs = Self.decodeVisibleTabs(savedTabs)
        quietFocusEnabled = Self.decodeBoolean(savedQuietFocus) ?? false

        // Repair only Broschy's own malformed keys, leaving unrelated settings intact.
        if let savedTabs, (savedTabs as? [Int]) != encodedVisibleTabs {
            persistVisibleTabs()
        }
        if savedQuietFocus != nil && Self.decodeBoolean(savedQuietFocus) == nil {
            defaults.set(false, forKey: Self.quietFocusKey)
        }
    }

    var orderedVisibleTabs: [PanelTab] {
        PanelTab.displayOrder.filter { visibleTabs.contains($0) }
    }

    var fallbackTab: PanelTab { orderedVisibleTabs.first ?? .focus }

    func safeSelection(_ requested: PanelTab?) -> PanelTab {
        if let requested, visibleTabs.contains(requested) { return requested }
        return fallbackTab
    }

    /// Hiding a module only changes presentation; it does not stop its background work.
    @discardableResult
    func setVisible(_ visible: Bool, for tab: PanelTab) -> Bool {
        guard visibleTabs.contains(tab) != visible else { return true }
        if !visible && visibleTabs.count == 1 { return false }
        if visible { visibleTabs.insert(tab) }
        else { visibleTabs.remove(tab) }
        persistVisibleTabs()
        return true
    }

    func resetDefaults() {
        visibleTabs = Self.defaultVisibleTabs
        quietFocusEnabled = false
        defaults.removeObject(forKey: Self.visibleTabsKey)
        defaults.removeObject(forKey: Self.quietFocusKey)
    }

    private var encodedVisibleTabs: [Int] { orderedVisibleTabs.map(\.rawValue) }

    private func persistVisibleTabs() {
        defaults.set(encodedVisibleTabs, forKey: Self.visibleTabsKey)
    }

    private static func decodeVisibleTabs(_ value: Any?) -> Set<PanelTab> {
        guard let values = value as? [Any] else { return defaultVisibleTabs }
        let tabs = Set(values.compactMap { value -> PanelTab? in
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let rawValue = Int(exactly: number.doubleValue) else { return nil }
            return PanelTab(rawValue: rawValue)
        })
        return tabs.isEmpty ? defaultVisibleTabs : tabs
    }

    private static func decodeBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// Quiet Focus changes compact interruptions, never the underlying Agents queue.
enum AgentAttentionPolicy {
    static func requiresInterruption(
        _ session: AgentSession,
        quietFocusEnabled: Bool,
        focusActive: Bool,
        now: Date = Date(),
        ownerLiveness: AgentProcessLiveness? = nil
    ) -> Bool {
        let status = session.effectiveStatus(at: now, ownerLiveness: ownerLiveness)
        var activeRequest = status == .needsAttention
        if status == .error && !session.pendingRequestIDs.isEmpty {
            // Preserve the error while applying request freshness and process-exit
            // rules to the unanswered question/permission that accompanies it.
            var pending = session
            pending.status = .needsAttention
            activeRequest = pending.effectiveStatus(at: now, ownerLiveness: ownerLiveness) == .needsAttention
        }
        if quietFocusEnabled && focusActive { return activeRequest }
        return activeRequest || ((status == .ready || status == .error) && session.acknowledgedAt == nil)
    }

    /// Pass the monitor's visible sessions so its retention and ordering remain unchanged.
    static func compactAttention(
        from sessions: [AgentSession],
        visibleTabs: Set<PanelTab>,
        quietFocusEnabled: Bool,
        focusActive: Bool,
        now: Date = Date()
    ) -> [AgentSession] {
        guard visibleTabs.contains(.agents) else { return [] }
        return sessions.filter {
            requiresInterruption($0, quietFocusEnabled: quietFocusEnabled,
                                 focusActive: focusActive, now: now)
        }
    }
}

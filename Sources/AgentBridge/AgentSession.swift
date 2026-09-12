import CryptoKit
import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude, opencode

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        }
    }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case idle, working, needsAttention, ready, error, closed, unknown
}

/// A deliberately small snapshot. It never contains prompts, tool input/output,
/// transcripts, permission descriptions, or generated conversation titles.
public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: AgentProvider
    public let sessionID: String
    public var cwd: String
    public var title: String
    public var status: AgentStatus
    public var detail: String
    public var updatedAt: Date
    public let startedAt: Date
    public var parentSessionID: String?
    public var pendingRequestIDs: [String]
    public var lastEvent: String
    public var acknowledgedAt: Date?

    // Bounded tombstones prevent late duplicate permission requests from
    // resurrecting a request whose response has already arrived.
    public var resolvedRequestIDs: [String]
    public var lastFailureAt: Date?
    public var ownerProcess: AgentProcessIdentity?

    public init(provider: AgentProvider, sessionID: String, cwd: String,
                status: AgentStatus = .idle, detail: String = "Session started",
                updatedAt: Date = Date(), startedAt: Date? = nil,
                parentSessionID: String? = nil, pendingRequestIDs: [String] = [],
                lastEvent: String = "SessionStart", acknowledgedAt: Date? = nil,
                ownerProcess: AgentProcessIdentity? = nil) {
        self.id = Self.stableID(provider: provider, sessionID: sessionID)
        self.provider = provider
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = Self.projectTitle(cwd)
        self.status = status
        self.detail = detail
        self.updatedAt = updatedAt
        self.startedAt = startedAt ?? updatedAt
        self.parentSessionID = parentSessionID
        self.pendingRequestIDs = pendingRequestIDs
        self.lastEvent = lastEvent
        self.acknowledgedAt = acknowledgedAt
        self.resolvedRequestIDs = []
        self.lastFailureAt = status == .error ? updatedAt : nil
        self.ownerProcess = ownerProcess
    }

    public static func stableID(provider: AgentProvider, sessionID: String) -> String {
        SHA256.hash(data: Data((provider.rawValue + "\u{0}" + sessionID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func effectiveStatus(at date: Date = Date(), ownerLiveness: AgentProcessLiveness? = nil) -> AgentStatus {
        // Finished responses/errors remain available for review after exit.
        guard [.working, .needsAttention, .idle, .unknown].contains(status) else { return status }
        let liveness = ownerProcess.map { ownerLiveness ?? $0.liveness() } ?? .unknown
        if liveness == .exited { return .closed }
        let age = date.timeIntervalSince(updatedAt)
        if liveness == .unknown && age > 75 { return .unknown }
        // An open process is not proof that a particular turn is still working.
        if liveness == .alive && status == .working && age > 120 {
            return .unknown
        }
        if liveness == .alive && status == .needsAttention && age > 30 * 60 {
            return .unknown
        }
        return status
    }

    public func status(at date: Date) -> AgentStatus { effectiveStatus(at: date) }

    public func needsAttention(at date: Date = Date()) -> Bool {
        let current = effectiveStatus(at: date)
        return current == .needsAttention || ((current == .ready || current == .error) && acknowledgedAt == nil)
    }

    static func projectTitle(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Agent session" : String(name.prefix(80))
    }

    var isValid: Bool {
        AgentEvent.validID(sessionID) && AgentEvent.validCWD(cwd)
            && id == Self.stableID(provider: provider, sessionID: sessionID)
            && title == Self.projectTitle(cwd)
            && detail.utf8.count <= 160 && AgentEvent.safeDetail(detail)
            && pendingRequestIDs.count <= 64 && resolvedRequestIDs.count <= 128
            && pendingRequestIDs.allSatisfy(AgentEvent.validID)
            && resolvedRequestIDs.allSatisfy(AgentEvent.validID)
            && Set(pendingRequestIDs).count == pendingRequestIDs.count
            && Set(pendingRequestIDs).isDisjoint(with: Set(resolvedRequestIDs))
            && (parentSessionID == nil || AgentEvent.validID(parentSessionID!))
            && AgentEvent.eventNames.contains(lastEvent)
            && (ownerProcess == nil || ownerProcess!.isValid(for: provider))
            && updatedAt.timeIntervalSince1970.isFinite && startedAt.timeIntervalSince1970.isFinite
    }
}

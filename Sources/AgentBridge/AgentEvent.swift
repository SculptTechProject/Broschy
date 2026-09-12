import Foundation

enum AgentEventKind: Equatable {
    case started, metadata, newTurn, working, attention, resolved, ready, error, idle, closed
}

struct AgentEvent {
    static let maximumInputBytes = 256 * 1_024
    let provider: AgentProvider
    let sessionID: String
    let cwd: String?
    let parentSessionID: String?
    let name: String
    let kind: AgentEventKind
    let detail: String
    let requestID: String?
    // A successful/failed tool callback proves the corresponding tool request
    // has resumed; unrelated busy events do not prove permission was granted.
    let resolvesToolRequest: Bool

    static let eventNames: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
        "Interrupt", "Elicitation", "ElicitationResult",
        "session.created", "session.updated", "session.deleted", "session.status", "session.idle", "session.error",
        "permission.asked", "permission.replied", "permission.updated", "question.asked",
        "question.replied", "question.rejected", "message.updated", "tool.execute.before", "tool.execute.after"
    ]

    private static let toolNames: Set<String> = [
        "Bash", "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "WebFetch", "WebSearch",
        "Task", "Agent", "TodoWrite", "NotebookEdit", "AskUserQuestion", "ExitPlanMode",
        "exec_command", "write_stdin", "apply_patch", "request_user_input", "spawn_agent",
        "wait_agent", "send_message", "shell", "shell_command", "read_file", "list_dir",
        "bash", "read", "write", "edit", "glob", "grep", "webfetch", "websearch", "task",
        "question", "todowrite", "todoread", "patch", "multiedit", "lsp"
    ]

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }
    }

    static func validCWD(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func safeDetail(_ value: String) -> Bool {
        ["Session started", "Working", "Waiting for permission", "Waiting for your answer",
         "Needs your attention", "Response received", "Ready to review", "Agent reported an error",
         "Tool reported an error", "Interrupted", "Idle", "Session ended", "Using a tool"].contains(value)
            || (value.hasPrefix("Using ") && toolNames.contains(String(value.dropFirst(6))))
    }

    static func parse(provider: AgentProvider, data: Data) throws -> AgentEvent? {
        guard data.count <= maximumInputBytes,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = payload["session_id"] as? String, validID(rawID),
              let name = payload["hook_event_name"] as? String, eventNames.contains(name) else {
            throw AgentBridgeError.invalidInput
        }
        let cwd = payload["cwd"] as? String
        if let cwd, !validCWD(cwd) { throw AgentBridgeError.invalidInput }
        let parent = payload["parent_session_id"] as? String
        if let parent, !validID(parent) { throw AgentBridgeError.invalidInput }
        let rawTool = payload["tool_name"] as? String
        let tool = rawTool.flatMap { value -> String? in
            let candidate = value.components(separatedBy: ".").last ?? value
            return toolNames.contains(candidate) ? candidate : nil
        }
        let toolDetail = tool.map { "Using " + $0 } ?? "Using a tool"
        let rawRequest = (payload["request_id"] ?? payload["tool_use_id"] ?? payload["call_id"] ?? payload["elicitation_id"]) as? String
        if let rawRequest, !validID(rawRequest) { throw AgentBridgeError.invalidInput }
        var request = rawRequest
        var kind: AgentEventKind
        var detail: String
        var resolvesToolRequest = false

        if provider == .opencode {
            switch name {
            case "session.created": kind = .started; detail = "Session started"
            case "session.updated": kind = .metadata; detail = "Session started"
            case "session.deleted": kind = .closed; detail = "Session ended"
            case "session.status":
                switch payload["status"] as? String {
                case "busy", "retry": kind = .working; detail = "Working"
                case "idle": kind = .ready; detail = "Ready to review"
                default: return nil
                }
            case "session.idle": kind = .ready; detail = "Ready to review"
            case "session.error": kind = .error; detail = "Agent reported an error"
            case "permission.asked", "permission.updated": kind = .attention; detail = "Waiting for permission"
            case "question.asked": kind = .attention; detail = "Waiting for your answer"
            case "permission.replied", "question.replied", "question.rejected":
                guard request != nil else { return nil }
                kind = .resolved; detail = "Response received"
            case "message.updated":
                guard payload["role"] as? String == "user" else { return nil }
                kind = .newTurn; detail = "Working"
            case "tool.execute.before":
                if tool == "question" { kind = .attention; detail = "Waiting for your answer" }
                else { kind = .working; detail = toolDetail }
            case "tool.execute.after": kind = .working; detail = toolDetail; resolvesToolRequest = true
            default: return nil
            }
        } else {
            switch name {
            case "SessionStart": kind = .started; detail = "Session started"
            case "SessionEnd": kind = .closed; detail = "Session ended"
            case "UserPromptSubmit": kind = .newTurn; detail = "Working"
            case "PreToolUse":
                if ["request_user_input", "AskUserQuestion", "question"].contains(tool ?? "") {
                    kind = .attention; detail = "Waiting for your answer"
                } else { kind = .working; detail = toolDetail }
            case "PostToolUse": kind = .working; detail = toolDetail; resolvesToolRequest = true
            case "PostToolUseFailure": kind = .error; detail = "Tool reported an error"; resolvesToolRequest = true
            case "PermissionRequest": kind = .attention; detail = "Waiting for permission"
            case "Elicitation": kind = .attention; detail = "Waiting for your answer"
            case "ElicitationResult": kind = .resolved; detail = "Response received"
            case "Notification":
                switch payload["notification_type"] as? String {
                case "permission_prompt": kind = .attention; detail = "Waiting for permission"
                case "elicitation_dialog": kind = .attention; detail = "Waiting for your answer"
                default: return nil
                }
            case "Stop": kind = .ready; detail = "Ready to review"
            case "StopFailure": kind = .error; detail = "Agent reported an error"
            case "Interrupt": kind = .idle; detail = "Interrupted"
            default: return nil
            }
        }
        if kind == .attention && request == nil {
            // Providers do not always attach an ID to UI notifications. Keep
            // that wait distinct from explicit permission IDs.
            request = detail == "Waiting for permission" ? "unidentified-permission" : "unidentified-question"
        }
        return AgentEvent(provider: provider, sessionID: rawID, cwd: cwd,
                          parentSessionID: parent, name: name, kind: kind,
                          detail: detail, requestID: request, resolvesToolRequest: resolvesToolRequest)
    }

    func applying(to previous: AgentSession?, now: Date) throws -> AgentSession {
        guard previous != nil || cwd != nil else { throw AgentBridgeError.invalidInput }
        var session = previous ?? AgentSession(provider: provider, sessionID: sessionID, cwd: cwd!, updatedAt: now)
        if now < session.updatedAt { return session }
        if let cwd { session.cwd = cwd; session.title = AgentSession.projectTitle(cwd) }
        if let parentSessionID { session.parentSessionID = parentSessionID }
        // Renames/directory metadata are not evidence that the agent is still
        // executing the last user turn. Preserve the activity timestamp/event.
        if kind == .metadata { return session }

        // A stray idle/Stop delivery cannot resurrect a session that ended.
        if session.status == .closed && kind != .started && kind != .newTurn { return session }
        let previousStatus = session.status
        session.updatedAt = now
        session.lastEvent = name

        if resolvesToolRequest {
            if let requestID { resolve(requestID, in: &session) }
            // ID-less notifications are resolved only by an explicit tool
            // completion or a new user turn, never by generic busy/idle.
            resolve("unidentified-permission", in: &session)
            resolve("unidentified-question", in: &session)
        }
        switch kind {
        case .started:
            if previous == nil || session.status == .closed {
                session.status = .idle; session.detail = detail
                session.pendingRequestIDs = []; session.resolvedRequestIDs = []
                session.lastFailureAt = nil
                session.acknowledgedAt = nil
            }
        case .metadata: break
        case .newTurn:
            session.status = .working; session.detail = detail; session.acknowledgedAt = nil
            session.lastFailureAt = nil
            resolve("unidentified-permission", in: &session)
            resolve("unidentified-question", in: &session)
        case .working:
            if session.status != .error { session.status = .working; session.detail = detail; session.acknowledgedAt = nil }
        case .attention:
            if let requestID, !session.resolvedRequestIDs.contains(requestID),
               !session.pendingRequestIDs.contains(requestID) {
                if session.pendingRequestIDs.count < 63 {
                    session.pendingRequestIDs.append(requestID)
                } else if !session.pendingRequestIDs.contains("untracked-request-overflow") {
                    // If an implausible number of simultaneous requests exceeds
                    // the bound, remain waiting instead of later claiming every
                    // request was resolved. This marker clears at session end.
                    session.pendingRequestIDs.append("untracked-request-overflow")
                }
            }
            if !session.pendingRequestIDs.isEmpty { session.status = .needsAttention; session.detail = detail; session.acknowledgedAt = nil }
        case .resolved:
            let wasPending = requestID.map { session.pendingRequestIDs.contains($0) }
                ?? session.pendingRequestIDs.contains("unidentified-question")
            if let requestID { resolve(requestID, in: &session) }
            else {
                resolve("unidentified-question", in: &session)
            }
            if wasPending && session.status != .error { session.status = .working; session.detail = detail; session.acknowledgedAt = nil }
        case .ready:
            if session.status != .error {
                session.status = .ready; session.detail = detail
                if previousStatus != .ready { session.acknowledgedAt = nil }
            }
        case .error:
            session.status = .error; session.detail = detail; session.acknowledgedAt = nil
            session.lastFailureAt = now
        case .idle:
            if session.status != .error { session.status = .idle; session.detail = detail; session.acknowledgedAt = nil }
        case .closed:
            session.status = .closed; session.detail = detail; session.pendingRequestIDs = []
        }
        if session.lastFailureAt != nil && session.status != .closed {
            session.status = .error; session.detail = "Agent reported an error"
        }
        if !session.pendingRequestIDs.isEmpty && session.status != .closed {
            session.status = .needsAttention
            if !["Waiting for permission", "Waiting for your answer"].contains(session.detail) {
                session.detail = "Needs your attention"
            }
        }
        return session
    }

    private func resolve(_ request: String, in session: inout AgentSession) {
        session.pendingRequestIDs.removeAll { $0 == request }
        // ID-less notifications must be able to recur during the next tool.
        guard !request.hasPrefix("unidentified-") else { return }
        if !session.resolvedRequestIDs.contains(request) { session.resolvedRequestIDs.append(request) }
        session.resolvedRequestIDs = Array(session.resolvedRequestIDs.suffix(128))
    }
}

public enum AgentBridgeError: Error {
    case invalidInput, unsafeStorage, busy, ioFailure
}

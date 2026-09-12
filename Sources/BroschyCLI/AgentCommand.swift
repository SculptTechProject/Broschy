import AgentBridge
import Darwin
import Foundation

func agentCommand(_ arguments: [String], store: AgentSessionStore = AgentSessionStore()) -> Int32 {
    guard let command = arguments.first else { return agentUsage() }
    let rest = Array(arguments.dropFirst())
    if command == "hook" {
        // Observation hooks must never reject a tool or emit agent instructions.
        // Codex Stop hooks require JSON even when no decision is being made.
        defer { print("{}") }
        guard rest.count == 2, rest[0] == "--provider", let provider = AgentProvider(rawValue: rest[1]) else { return 0 }
        let owner = AgentProcessIdentity.captureOwner(provider: provider)
        do { _ = try store.ingest(provider: provider, data: boundedAgentInput(), ownerProcess: owner) }
        catch { /* Fail open, without printing private payload/error text. */ }
        return 0
    }
    if command == "list", rest.isEmpty {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(store.readSessions()))
            print("")
            return 0
        } catch { diagnostic("Cannot read agent snapshots."); return 74 }
    }
    if command == "acknowledge", rest.count == 4, rest[0] == "--provider",
       let provider = AgentProvider(rawValue: rest[1]), rest[2] == "--session" {
        do { _ = try store.acknowledge(provider: provider, sessionID: rest[3]); return 0 }
        catch { diagnostic("Cannot acknowledge this agent session."); return 74 }
    }
    return agentUsage()
}

private func agentUsage() -> Int32 {
    diagnostic("Expected agent hook --provider codex|claude|opencode, agent list, or agent acknowledge --provider <provider> --session <id>.")
    return 64
}

private func boundedAgentInput() throws -> Data {
    let limit = 256 * 1_024
    var result = Data()
    // Bound time as well as size: an accidentally open stdin must not hang a hook.
    let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
        let ready = poll(&descriptor, 1, Int32(min(100, remaining / 1_000_000)))
        if ready < 0 { if errno == EINTR { continue }; throw AgentBridgeError.ioFailure }
        if ready == 0 { continue }
        if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { throw AgentBridgeError.ioFailure }
        var buffer = [UInt8](repeating: 0, count: min(8_192, limit + 1 - result.count))
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count == 0 { return result }
        if count < 0 { if errno == EINTR { continue }; throw AgentBridgeError.ioFailure }
        result.append(contentsOf: buffer.prefix(count))
        guard result.count <= limit else { throw AgentBridgeError.invalidInput }
    }
    throw AgentBridgeError.busy
}

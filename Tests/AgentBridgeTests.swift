import AgentBridge
import Darwin
import Dispatch
import Foundation

// AgentCommand.swift is included so pipe behavior is checked against the exact
// production hook entry point, always with an isolated snapshot directory.
func diagnostic(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Agent bridge check failed") rethrows {
    let passed = try condition()
    precondition(passed, message)
}

@main
enum AgentBridgeTests {
    static func main() throws {
        if (3...4).contains(CommandLine.arguments.count) && CommandLine.arguments[1] == "--hook-child" {
            let provider = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "codex"
            exit(agentCommand(["hook", "--provider", provider],
                              store: AgentSessionStore(rootDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))))
        }
        if (4...5).contains(CommandLine.arguments.count) && CommandLine.arguments[1] == "--owner-child" {
            // A copied test executable has the provider's actual native binary
            // basename, but makes no network/model calls. Its child runs the
            // production hook handler to exercise real ancestry capture.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let provider = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "codex"
            child.arguments = ["--hook-child", CommandLine.arguments[3], provider]
            let input = Pipe(), output = Pipe()
            child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
            try child.run()
            let event: [String: Any] = ["hook_event_name": provider == "opencode" ? "message.updated" : "UserPromptSubmit", "role": "user", "session_id": "owned-session",
                                       "cwd": "/tmp/owned-project", "owner_pid": 1,
                                       "ownerProcess": ["pid": 1, "executableName": "forged-owner"]]
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
            try input.fileHandleForWriting.close()
            let neutral = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, String(decoding: neutral, as: UTF8.self) == "{}\n" else { exit(2) }
            FileHandle.standardOutput.write(Data("ready\n".utf8))
            Thread.sleep(forTimeInterval: 30)
            exit(0)
        }
        guard CommandLine.arguments.count == 2 else { fatalError("Pass an isolated test directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("agent-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let secrets = "NEVER-PERSIST-PROMPT-COMMAND-OUTPUT-OR-PERMISSION-SECRET"

        func payload(_ event: String, id: String = "session-1", extra: [String: Any] = [:]) throws -> Data {
            var object: [String: Any] = ["hook_event_name": event, "session_id": id, "cwd": "/tmp/my-project",
                                       "prompt": secrets, "tool_input": ["command": secrets], "tool_response": secrets,
                                       "transcript_path": secrets, "title": secrets, "message": secrets,
                                       "permission_suggestions": [["description": secrets]]]
            object.merge(extra) { _, value in value }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let store = AgentSessionStore(rootDirectory: root.appendingPathComponent("normal"))
        try check(try store.readSessions().isEmpty, "Read-only discovery must tolerate an unconfigured bridge.")
        precondition(!FileManager.default.fileExists(atPath: store.rootDirectory.path))
        _ = try store.ingest(provider: .claude, data: payload("SessionStart"), now: now)
        var session = try store.ingest(provider: .claude, data: payload("PreToolUse", extra: ["tool_name": secrets]), now: now)!
        precondition(session.title == "my-project" && session.detail == "Using a tool")
        let files = try FileManager.default.contentsOfDirectory(at: store.sessionsDirectory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let serialized = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            precondition(!serialized.contains(secrets), "Hooks must whitelist metadata before persistence.")
            precondition(!serialized.contains("transcript") && !serialized.contains("tool_input"))
        }
        _ = try store.ingest(provider: .codex, data: payload("SessionStart"), now: now)
        _ = try store.ingest(provider: .opencode, data: payload("session.created"), now: now)
        try check(try store.readSessions().count == 3, "Provider session IDs must not collide.")
        print("PASS: metadata redaction, generic unknown tools, project titles, provider-separated identities")

        let waits = AgentSessionStore(rootDirectory: root.appendingPathComponent("waits"))
        _ = try waits.ingest(provider: .opencode, data: payload("permission.asked", extra: ["request_id": "p1"]), now: now)
        _ = try waits.ingest(provider: .opencode, data: payload("question.asked", extra: ["request_id": "q1"]), now: now)
        session = try waits.ingest(provider: .opencode, data: payload("session.idle"), now: now)!
        precondition(session.status == .needsAttention && session.pendingRequestIDs.count == 2)
        session = try waits.acknowledge(provider: .opencode, sessionID: "session-1", now: now)!
        precondition(session.acknowledgedAt == nil && session.needsAttention(at: now), "Review cannot approve an active request.")
        session = try waits.ingest(provider: .opencode, data: payload("permission.replied", extra: ["request_id": "p1"]), now: now)!
        precondition(session.status == .needsAttention && session.pendingRequestIDs == ["q1"])
        session = try waits.ingest(provider: .opencode, data: payload("permission.replied", extra: ["request_id": "p1"]), now: now)!
        precondition(session.status == .needsAttention && session.pendingRequestIDs == ["q1"])
        session = try waits.ingest(provider: .opencode, data: payload("permission.asked", extra: ["request_id": "p1"]), now: now)!
        precondition(session.pendingRequestIDs == ["q1"], "A late duplicate request must not resurrect a replied request.")
        session = try waits.ingest(provider: .opencode, data: payload("question.replied", extra: ["request_id": "q1"]), now: now)!
        precondition(session.status == .working && session.pendingRequestIDs.isEmpty)
        session = try waits.ingest(provider: .opencode, data: payload("session.idle"), now: now)!
        precondition(session.status == .ready && session.needsAttention(at: now))
        _ = try waits.acknowledge(provider: .opencode, sessionID: "session-1", now: now)
        session = try waits.ingest(provider: .opencode, data: payload("session.status", extra: ["status": "idle"]), now: now)!
        precondition(session.acknowledgedAt == now && !session.needsAttention(at: now), "Duplicate idle must preserve review acknowledgment.")
        session = try waits.ingest(provider: .opencode, data: payload("question.replied", extra: ["request_id": "q1"]), now: now)!
        precondition(session.status == .ready && session.acknowledgedAt == now, "Duplicate reply must not restart a completed turn.")
        print("PASS: independent permission/question waits, idempotent replies, no false completion, review acknowledgment")

        let oldResponse = session
        _ = try waits.ingest(provider: .opencode, data: payload("message.updated", extra: ["role": "user"]), now: now.addingTimeInterval(0.125))
        _ = try waits.ingest(provider: .opencode, data: payload("session.idle"), now: now.addingTimeInterval(0.250))
        session = try waits.acknowledge(provider: .opencode, sessionID: "session-1", expectedUpdatedAt: oldResponse.updatedAt, now: now.addingTimeInterval(0.375))!
        precondition(session.status == .ready && session.acknowledgedAt == nil, "A stale row must not acknowledge a newer unseen response.")
        _ = try waits.acknowledge(provider: .opencode, sessionID: "session-1", expectedUpdatedAt: session.updatedAt, now: now.addingTimeInterval(0.375))
        try check(try waits.readSessions().first?.acknowledgedAt != nil)
        print("PASS: stale-row acknowledgment does not dismiss newer unseen responses")

        // Use a fresh session so reducer clock-order protection also stays active.
        let lifecycle = AgentSessionStore(rootDirectory: root.appendingPathComponent("lifecycle"))
        session = try lifecycle.ingest(provider: .opencode, data: payload("session.error"), now: now)!
        session = try lifecycle.ingest(provider: .opencode, data: payload("session.idle"), now: now)!
        precondition(session.status == .error, "Idle after error must not report success.")
        _ = try lifecycle.ingest(provider: .opencode, data: payload("permission.asked", extra: ["request_id": "p2"]), now: now)
        session = try lifecycle.ingest(provider: .opencode, data: payload("permission.replied", extra: ["request_id": "p2"]), now: now)!
        precondition(session.status == .error, "Resolving a request must not erase the earlier error.")
        session = try lifecycle.ingest(provider: .opencode, data: payload("message.updated", extra: ["role": "user"]), now: now)!
        precondition(session.status == .working && session.lastFailureAt == nil)
        precondition(session.effectiveStatus(at: now.addingTimeInterval(1_801)) == .unknown)
        _ = try lifecycle.ingest(provider: .opencode, data: payload("question.asked", extra: ["request_id": "q2"]), now: now)
        session = try lifecycle.readSessions().first!
        precondition(session.effectiveStatus(at: now.addingTimeInterval(1_801)) == .unknown && !session.needsAttention(at: now.addingTimeInterval(1_801)))
        session = try lifecycle.ingest(provider: .opencode, data: payload("session.deleted"), now: now)!
        session = try lifecycle.ingest(provider: .opencode, data: payload("session.idle"), now: now)!
        precondition(session.status == .closed && session.pendingRequestIDs.isEmpty)
        session = try lifecycle.ingest(provider: .opencode, data: payload("message.updated", extra: ["role": "user"]), now: now)!
        precondition(session.status == .working)
        _ = try lifecycle.ingest(provider: .opencode, data: payload("session.updated", extra: ["cwd": "/tmp/renamed-project"]), now: now)
        try check(try lifecycle.readSessions().first?.title == "renamed-project")
        print("PASS: sticky errors, new-turn recovery, stale status, closed sessions, metadata-only updates")

        let codex = AgentSessionStore(rootDirectory: root.appendingPathComponent("codex"))
        _ = try codex.ingest(provider: .codex, data: payload("PreToolUse", extra: ["tool_name": "request_user_input", "tool_use_id": "tool1"]), now: now)
        session = try codex.ingest(provider: .codex, data: payload("Stop"), now: now)!
        precondition(session.status == .needsAttention)
        session = try codex.ingest(provider: .codex, data: payload("PostToolUse", extra: ["tool_name": "request_user_input", "tool_use_id": "tool1"]), now: now)!
        precondition(session.status == .working && session.pendingRequestIDs.isEmpty)
        session = try codex.ingest(provider: .codex, data: payload("Interrupt"), now: now)!
        precondition(session.status == .idle)
        _ = try codex.ingest(provider: .codex, data: payload("StopFailure"), now: now)
        session = try codex.ingest(provider: .codex, data: payload("Stop"), now: now)!
        precondition(session.status == .error)
        print("PASS: Codex user-input waits, tool resumption, interruption, StopFailure preservation")

        let elicitation = AgentSessionStore(rootDirectory: root.appendingPathComponent("elicitation"))
        _ = try elicitation.ingest(provider: .claude, data: payload("Elicitation", extra: ["elicitation_id": "elicit-1"]), now: now)
        _ = try elicitation.ingest(provider: .claude, data: payload("Elicitation", extra: ["elicitation_id": "elicit-2"]), now: now)
        session = try elicitation.ingest(provider: .claude, data: payload("ElicitationResult", extra: ["elicitation_id": "elicit-1", "content": ["private": secrets]]), now: now)!
        precondition(session.status == .needsAttention && session.pendingRequestIDs == ["elicit-2"])
        session = try elicitation.ingest(provider: .claude, data: payload("ElicitationResult", extra: ["elicitation_id": "elicit-2", "action": "decline"]), now: now)!
        precondition(session.status == .working && session.pendingRequestIDs.isEmpty)
        session = try elicitation.ingest(provider: .claude, data: payload("Stop"), now: now)!
        precondition(session.status == .ready)
        _ = try elicitation.ingest(provider: .claude, data: payload("Elicitation"), now: now)
        session = try elicitation.ingest(provider: .claude, data: payload("ElicitationResult"), now: now)!
        precondition(session.status == .working && session.pendingRequestIDs.isEmpty)
        let elicitationJSON = try Data(contentsOf: elicitation.sessionsDirectory.appendingPathComponent(session.id + ".json"))
        precondition(!String(decoding: elicitationJSON, as: UTF8.self).contains(secrets))
        print("PASS: Claude elicitation IDs, independent replies, ID-less results, and private response redaction")

        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Unsafe input/storage must be rejected") }
            catch { }
        }
        rejects { _ = try store.ingest(provider: .claude, data: payload("SessionStart", id: "../../escaped"), now: now) }
        rejects { _ = try store.ingest(provider: .claude, data: payload("SessionStart", extra: ["cwd": "relative/path"]), now: now) }
        rejects { _ = try store.ingest(provider: .claude, data: Data(repeating: 32, count: 256 * 1_024 + 1), now: now) }
        let symbolic = root.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: store.rootDirectory)
        rejects { _ = try AgentSessionStore(rootDirectory: symbolic).ingest(provider: .claude, data: payload("SessionStart"), now: now) }
        let unsafe = AgentSessionStore(rootDirectory: root.appendingPathComponent("unsafe"))
        _ = try unsafe.ingest(provider: .claude, data: payload("SessionStart"), now: now)
        let snapshot = unsafe.sessionsDirectory.appendingPathComponent(AgentSession.stableID(provider: .claude, sessionID: "session-1") + ".json")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: root.appendingPathComponent("outside"))
        rejects { _ = try unsafe.ingest(provider: .claude, data: payload("Stop"), now: now) }
        try check(try unsafe.readSessions().isEmpty)
        try FileManager.default.removeItem(at: snapshot)
        try Data(repeating: 32, count: 64 * 1_024 + 1).write(to: snapshot)
        try check(try unsafe.readSessions().isEmpty)
        print("PASS: invalid IDs/paths, oversized inputs/snapshots, symlink storage rejection")

        let concurrent = AgentSessionStore(rootDirectory: root.appendingPathComponent("concurrent"))
        _ = try concurrent.ingest(provider: .opencode, data: payload("session.created"), now: now)
        let lock = NSLock()
        var failures = 0
        let requests = try (0..<24).map { try payload("permission.asked", extra: ["request_id": "parallel-\($0)"]) }
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            do { _ = try concurrent.ingest(provider: .opencode, data: requests[index], now: now) }
            catch { lock.lock(); failures += 1; lock.unlock() }
        }
        precondition(failures == 0)
        try check(try concurrent.readSessions().first?.pendingRequestIDs.count == requests.count, "Concurrent read-modify-write must not lose pending requests.")
        print("PASS: concurrent per-session hook updates retain every pending request")

        let recent = AgentSessionStore(rootDirectory: root.appendingPathComponent("recent"))
        for index in 0..<4 {
            let record = try recent.ingest(provider: .codex, data: payload("SessionStart", id: "recent-\(index)"), now: now.addingTimeInterval(Double(index)))!
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index))],
                                                  ofItemAtPath: recent.sessionsDirectory.appendingPathComponent(record.id + ".json").path)
        }
        let visibleRecent = try recent.readSessions(limit: 2)
        precondition(visibleRecent.map(\.sessionID) == ["recent-3", "recent-2"], "Bounded discovery must prioritize recent sessions, not arbitrary directory order.")
        print("PASS: bounded discovery prioritizes newest session files")

        let ownerExecutable = root.appendingPathComponent("codex-aarch64-apple-darwin")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: ownerExecutable)
        func launchOwner(_ name: String, executable: URL? = nil, provider: String = "codex") throws -> (Process, AgentSessionStore) {
            let target = AgentSessionStore(rootDirectory: root.appendingPathComponent(name))
            let process = Process()
            process.executableURL = executable ?? ownerExecutable
            process.arguments = ["--owner-child", CommandLine.arguments[0], target.rootDirectory.path, provider]
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 5_000) == 1 else {
                process.terminate(); process.waitUntilExit()
                fatalError("Fixture owner did not emit its hook within five seconds")
            }
            let line = output.fileHandleForReading.readData(ofLength: 6)
            precondition(String(decoding: line, as: UTF8.self) == "ready\n")
            return (process, target)
        }
        let (owner, ownedStore) = try launchOwner("owner-1")
        defer { if owner.isRunning { owner.terminate(); owner.waitUntilExit() } }
        let owned = try ownedStore.readSessions().first!
        let identity = owned.ownerProcess!
        precondition(identity.pid == owner.processIdentifier && identity.executableName == "codex-aarch64-apple-darwin")
        precondition(identity.startedAtSeconds > 0 && identity.startedAtMicroseconds < 1_000_000)
        precondition(identity.liveness() == .alive && owned.effectiveStatus() == .working)
        precondition(AgentProcessIdentity.captureOwner(provider: .claude, startingAt: owner.processIdentifier) == nil,
                     "A different provider must not adopt this owner.")
        let reusedPID = AgentProcessIdentity(pid: identity.pid, startedAtSeconds: identity.startedAtSeconds - 1,
                                             startedAtMicroseconds: identity.startedAtMicroseconds, executableName: identity.executableName)
        precondition(reusedPID.liveness() == .exited, "An existing PID with a different start time is not the original owner.")
        precondition(owned.effectiveStatus(at: owned.updatedAt.addingTimeInterval(121)) == .unknown,
                     "A live terminal alone must not imply ongoing work forever.")
        var waitingOwner = owned
        waitingOwner.status = .needsAttention
        waitingOwner.pendingRequestIDs = ["pending-question"]
        precondition(waitingOwner.effectiveStatus(at: owned.updatedAt.addingTimeInterval(900)) == .needsAttention,
                     "A question may legitimately await a response while its exact owner stays alive.")
        precondition(waitingOwner.effectiveStatus(at: owned.updatedAt.addingTimeInterval(1_801)) == .unknown,
                     "A missed reply must not pin the notch indefinitely even if the process remains alive.")
        let (unrelatedOwner, _) = try launchOwner("owner-2")
        defer { if unrelatedOwner.isRunning { unrelatedOwner.terminate(); unrelatedOwner.waitUntilExit() } }
        owner.terminate(); owner.waitUntilExit()
        precondition(unrelatedOwner.isRunning && identity.liveness() == .exited)
        precondition(owned.effectiveStatus() == .closed && waitingOwner.effectiveStatus() == .closed,
                     "Owner exit without SessionEnd must immediately clear active work/waits, even with another Codex process open.")
        var reviewAfterExit = owned
        reviewAfterExit.status = .ready
        precondition(reviewAfterExit.effectiveStatus() == .ready)
        reviewAfterExit.status = .error
        precondition(reviewAfterExit.effectiveStatus() == .error)
        let resumedIdentity = AgentProcessIdentity.captureOwner(provider: .codex, startingAt: unrelatedOwner.processIdentifier)!
        let resumed = try ownedStore.ingest(provider: .codex, data: payload("UserPromptSubmit", id: "owned-session"),
                                            now: Date(), ownerProcess: resumedIdentity)!
        precondition(resumed.ownerProcess == resumedIdentity && resumed.effectiveStatus() == .working,
                     "Resuming a session must adopt the new invocation's identity.")
        let unverified = try ownedStore.ingest(provider: .codex, data: payload("PreToolUse", id: "owned-session"), now: Date())!
        precondition(unverified.ownerProcess == nil, "A delivery without verified ancestry must not retain an unrelated old owner.")
        precondition(unverified.effectiveStatus(at: unverified.updatedAt.addingTimeInterval(76)) == .unknown)
        let spoofed = try ownedStore.ingest(provider: .codex,
            data: payload("UserPromptSubmit", id: "spoofed-session", extra: ["owner_pid": unrelatedOwner.processIdentifier,
                       "ownerProcess": ["pid": unrelatedOwner.processIdentifier, "executableName": "codex-aarch64-apple-darwin"]]), now: Date())!
        precondition(spoofed.ownerProcess == nil, "Raw hook payloads must never assign process identity.")
        let oldEncoder = JSONEncoder()
        oldEncoder.dateEncodingStrategy = .secondsSince1970
        let oldDecoder = JSONDecoder()
        oldDecoder.dateDecodingStrategy = .secondsSince1970
        let legacyJSON = try oldEncoder.encode(spoofed)
        precondition(!String(decoding: legacyJSON, as: UTF8.self).contains("ownerProcess"))
        let legacy = try oldDecoder.decode(AgentSession.self, from: legacyJSON)
        precondition(legacy.ownerProcess == nil && legacy.effectiveStatus(at: legacy.updatedAt.addingTimeInterval(76)) == .unknown)
        precondition(owned.effectiveStatus(at: owned.updatedAt.addingTimeInterval(76), ownerLiveness: .unknown) == .unknown,
                     "An indeterminate process lookup must not claim the owner exited or still works.")
        let opencodeExecutable = root.appendingPathComponent("opencode.exe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: opencodeExecutable)
        let (opencodeOwner, opencodeStore) = try launchOwner("opencode-native", executable: opencodeExecutable, provider: "opencode")
        defer { if opencodeOwner.isRunning { opencodeOwner.terminate(); opencodeOwner.waitUntilExit() } }
        let opencodeSession = try opencodeStore.readSessions().first!
        precondition(opencodeSession.ownerProcess?.pid == opencodeOwner.processIdentifier && opencodeSession.ownerProcess?.executableName == "opencode.exe",
                     "The installed native OpenCode basename on macOS must be recognized.")
        let staleMoment = opencodeSession.updatedAt.addingTimeInterval(121)
        let metadataOnly = try opencodeStore.ingest(provider: .opencode,
            data: payload("session.updated", id: "owned-session", extra: ["cwd": "/tmp/renamed-owned-project"]),
            now: staleMoment, ownerProcess: opencodeSession.ownerProcess)!
        precondition(metadataOnly.title == "renamed-owned-project" && metadataOnly.updatedAt == opencodeSession.updatedAt
                     && metadataOnly.lastEvent == opencodeSession.lastEvent && metadataOnly.effectiveStatus(at: staleMoment) == .unknown,
                     "Metadata updates must not refresh or revive stale working status.")
        print("PASS: real owner exit without SessionEnd, exact PID/start identity, unrelated live owners, bounded freshness, pending waits, resume, payload spoof rejection, legacy snapshots")

        func invokeHook(_ input: Data, keepPipeOpen: Bool = false) throws -> (Int32, String, String, TimeInterval) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--hook-child", root.appendingPathComponent("cli").path]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            let began = Date()
            try process.run()
            stdin.fileHandleForWriting.write(input)
            if !keepPipeOpen { try stdin.fileHandleForWriting.close() }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errors = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if keepPipeOpen { try stdin.fileHandleForWriting.close() }
            return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self), Date().timeIntervalSince(began))
        }
        let success = try invokeHook(payload("Stop"))
        precondition(success.0 == 0 && success.1 == "{}\n" && success.2.isEmpty)
        let invalid = try invokeHook(Data(("invalid " + secrets).utf8))
        precondition(invalid.0 == 0 && invalid.1 == "{}\n" && invalid.2.isEmpty)
        let unclosed = try invokeHook(Data("{".utf8), keepPipeOpen: true)
        precondition(unclosed.0 == 0 && unclosed.1 == "{}\n" && unclosed.2.isEmpty && unclosed.3 < 3)
        let cliSessions = try AgentSessionStore(rootDirectory: root.appendingPathComponent("cli")).readSessions()
        precondition(cliSessions.count == 1 && cliSessions[0].status == .ready)
        print("PASS: hook pipes return neutral JSON, fail open, redact errors, and time out bounded stdin")
    }
}

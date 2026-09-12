import Darwin
import Foundation

/// Separate per-session snapshots let short-lived hooks update concurrently.
/// Writes use an advisory lock and atomic rename; readers never see partial JSON.
public struct AgentSessionStore: Sendable {
    public let rootDirectory: URL
    public var sessionsDirectory: URL { rootDirectory.appendingPathComponent("sessions", isDirectory: true) }
    private static let maximumSnapshotBytes = 64 * 1_024

    public init(rootDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rootDirectory = rootDirectory ?? support.appendingPathComponent("NotchFlow/agents", isDirectory: true)
    }

    /// Reading does not create directories or modify agent configuration.
    public func readSessions(limit: Int = 512) throws -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        try checkDirectory(rootDirectory.deletingLastPathComponent())
        try checkDirectory(rootDirectory)
        try checkDirectory(sessionsDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }
            .map { file in (file: file, modified: (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
            .prefix(min(512, max(1, limit)))
        return files.compactMap { file in
            guard let session = try? read(file.file), session.id + ".json" == file.file.lastPathComponent else { return nil }
            return session
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func ingest(provider: AgentProvider, data: Data, now: Date = Date(),
                       ownerProcess: AgentProcessIdentity? = nil) throws -> AgentSession? {
        guard let event = try AgentEvent.parse(provider: provider, data: data) else { return nil }
        let id = AgentSession.stableID(provider: provider, sessionID: event.sessionID)
        return try withSessionLock(id: id) {
            let file = sessionsDirectory.appendingPathComponent(id + ".json")
            let existing = try readIfPresent(file)
            var result = try event.applying(to: existing, now: now)
            if event.kind != .metadata && result != existing {
                // Identity belongs to this delivery, not a previous terminal
                // invocation of the same resumed session. Missing evidence
                // falls back to the short unverified freshness window.
                result.ownerProcess = ownerProcess
            }
            guard result.isValid else { throw AgentBridgeError.invalidInput }
            if result != existing { try write(result, to: file) }
            return result
        }
    }

    /// Active permission requests always need a response in the agent's own app.
    @discardableResult
    public func acknowledge(provider: AgentProvider, sessionID: String, expectedUpdatedAt: Date? = nil,
                            now: Date = Date()) throws -> AgentSession? {
        guard AgentEvent.validID(sessionID) else { throw AgentBridgeError.invalidInput }
        let id = AgentSession.stableID(provider: provider, sessionID: sessionID)
        return try withSessionLock(id: id) {
            let file = sessionsDirectory.appendingPathComponent(id + ".json")
            guard var session = try readIfPresent(file) else { return nil }
            if let expectedUpdatedAt, session.updatedAt != expectedUpdatedAt { return session }
            if session.pendingRequestIDs.isEmpty && [.ready, .error].contains(session.status) {
                session.acknowledgedAt = now
                try write(session, to: file)
            }
            return session
        }
    }

    private func prepareDirectory() throws {
        let parent = rootDirectory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { try checkDirectory(parent) }
        for directory in [rootDirectory, sessionsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            try checkDirectory(directory)
        }
    }

    private func checkDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else { throw AgentBridgeError.unsafeStorage }
    }

    private func withSessionLock<T>(id: String, _ action: () throws -> T) throws -> T {
        try prepareDirectory()
        let lockURL = sessionsDirectory.appendingPathComponent(id + ".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentBridgeError.unsafeStorage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw AgentBridgeError.unsafeStorage }
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw AgentBridgeError.ioFailure }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw AgentBridgeError.busy }
            usleep(5_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    private func readIfPresent(_ file: URL) throws -> AgentSession? {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw AgentBridgeError.ioFailure
        }
        return try read(file)
    }

    private func read(_ file: URL) throws -> AgentSession {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw AgentBridgeError.unsafeStorage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0,
              info.st_size <= Self.maximumSnapshotBytes else { throw AgentBridgeError.unsafeStorage }
        var data = Data(count: Int(info.st_size))
        let expected = data.count
        let amount = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, expected) }
        guard amount == expected else { throw AgentBridgeError.ioFailure }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(AgentSession.self, from: data)
        guard session.isValid else { throw AgentBridgeError.invalidInput }
        return session
    }

    private func write(_ session: AgentSession, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(session)
        guard data.count <= Self.maximumSnapshotBytes else { throw AgentBridgeError.invalidInput }
        let temporary = sessionsDirectory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentBridgeError.ioFailure }
        defer { close(descriptor); unlink(temporary.path) }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, data.count) }
        guard written == data.count, fsync(descriptor) == 0,
              rename(temporary.path, file.path) == 0 else { throw AgentBridgeError.ioFailure }
    }
}

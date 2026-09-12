import Darwin
import Foundation

public enum AgentProcessLiveness: Sendable {
    case alive, exited, unknown
}

/// An exact local process identity. PID alone is insufficient because macOS
/// reuses it after exit. No executable path or command-line arguments are saved.
public struct AgentProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedAtSeconds: UInt64
    public let startedAtMicroseconds: UInt64
    public let executableName: String

    public init(pid: Int32, startedAtSeconds: UInt64, startedAtMicroseconds: UInt64,
                executableName: String) {
        self.pid = pid
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
        self.executableName = executableName
    }

    /// Inspect only the hook's ancestry, never all processes with a matching
    /// name. A different Codex window must not keep an old session "Working".
    public static func captureOwner(provider: AgentProvider, startingAt pid: Int32 = getppid()) -> Self? {
        var currentPID = pid
        var visited = Set<Int32>()
        for _ in 0..<8 {
            guard currentPID > 1, visited.insert(currentPID).inserted,
                  let info = processInfo(currentPID), info.pbi_uid == getuid() else { return nil }
            if let path = executablePath(currentPID) {
                let name = URL(fileURLWithPath: path).lastPathComponent
                // The desktop app-server is long-lived and shared across tasks.
                // It cannot establish ownership of a terminal CLI session.
                if !path.contains(".app/Contents/"), names(for: provider).contains(name),
                   let confirmed = processInfo(currentPID),
                   confirmed.pbi_start_tvsec == info.pbi_start_tvsec,
                   confirmed.pbi_start_tvusec == info.pbi_start_tvusec,
                   confirmed.pbi_status != UInt32(SZOMB) {
                    let identity = Self(pid: currentPID, startedAtSeconds: info.pbi_start_tvsec,
                                        startedAtMicroseconds: info.pbi_start_tvusec, executableName: name)
                    return identity.isValid(for: provider) ? identity : nil
                }
            }
            guard info.pbi_ppid <= UInt32(Int32.max) else { return nil }
            currentPID = Int32(info.pbi_ppid)
        }
        return nil
    }

    public func liveness() -> AgentProcessLiveness {
        guard pid > 1, startedAtSeconds > 0, startedAtMicroseconds < 1_000_000 else { return .unknown }
        guard let info = Self.processInfo(pid) else {
            // EPERM/limited process visibility is uncertainty, not proof of exit.
            return kill(pid, 0) == -1 && errno == ESRCH ? .exited : .unknown
        }
        guard info.pbi_start_tvsec == startedAtSeconds,
              info.pbi_start_tvusec == startedAtMicroseconds else { return .exited }
        if info.pbi_status == UInt32(SZOMB) { return .exited }
        guard info.pbi_uid == getuid(), let path = Self.executablePath(pid) else { return .unknown }
        guard URL(fileURLWithPath: path).lastPathComponent == executableName else { return .exited }
        guard let confirmed = Self.processInfo(pid) else {
            return kill(pid, 0) == -1 && errno == ESRCH ? .exited : .unknown
        }
        guard confirmed.pbi_start_tvsec == startedAtSeconds,
              confirmed.pbi_start_tvusec == startedAtMicroseconds,
              confirmed.pbi_status != UInt32(SZOMB) else { return .exited }
        return .alive
    }

    func isValid(for provider: AgentProvider) -> Bool {
        pid > 1 && startedAtSeconds > 0 && startedAtMicroseconds < 1_000_000
            && startedAtSeconds <= UInt64(Date().timeIntervalSince1970 + 60)
            && Self.names(for: provider).contains(executableName)
    }

    private static func names(for provider: AgentProvider) -> Set<String> {
        switch provider {
        case .codex: return ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"]
        case .claude: return ["claude"]
        case .opencode: return ["opencode", "opencode.exe", "opencode-darwin-arm64", "opencode-darwin-x64"]
        }
    }

    private static func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression unavailable to Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

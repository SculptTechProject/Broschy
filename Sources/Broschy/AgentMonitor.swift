import AgentBridge
import AppKit
import Combine
import Foundation

@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var storageError: String?
    private let storage: AgentSessionStore
    private let queue = DispatchQueue(label: "app.broschy.agents", qos: .utility)
    private var ticker: Timer?
    private var refreshing = false

    init(rootDirectory: URL? = nil, startTicker: Bool = true) {
        storage = AgentSessionStore(rootDirectory: rootDirectory)
        if startTicker {
            refresh()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    deinit { ticker?.invalidate() }

    var visibleSessions: [AgentSession] {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        return sessions.filter { $0.updatedAt > cutoff && $0.effectiveStatus() != .closed }
    }
    var attention: [AgentSession] { visibleSessions.filter { $0.needsAttention() } }
    var others: [AgentSession] { visibleSessions.filter { !$0.needsAttention() } }
    var workingCount: Int { visibleSessions.filter { $0.effectiveStatus() == .working }.count }
    var needsYouCount: Int { attention.count }
    var hasCompactActivity: Bool { needsYouCount > 0 || workingCount > 0 }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let storage = storage
        queue.async { [weak self] in
            let result = Result { try storage.readSessions() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch result {
                case .success(let sessions):
                    // Publish on each tick so stale activity ages out even without a new file.
                    self.sessions = sessions.sorted { lhs, rhs in
                        if lhs.needsAttention() != rhs.needsAttention() { return lhs.needsAttention() }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    self.storageError = nil
                case .failure:
                    self.sessions = []
                    self.storageError = "Could not read agent status. Check access to Broschy’s data folder."
                }
            }
        }
    }

    func acknowledge(_ session: AgentSession) {
        let storage = storage
        queue.async { [weak self] in
            do {
                try storage.acknowledge(provider: session.provider, sessionID: session.sessionID, expectedUpdatedAt: session.updatedAt)
                DispatchQueue.main.async { self?.refresh() }
            } catch {
                DispatchQueue.main.async { self?.storageError = "Could not mark this session as reviewed." }
            }
        }
    }

    func copyResumeCommand(_ session: AgentSession) {
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command: String
        switch session.provider {
        case .codex: command = "codex resume -C \(quote(session.cwd)) -- \(quote(session.sessionID))"
        case .claude: command = "cd \(quote(session.cwd)) && claude --resume=\(quote(session.sessionID))"
        case .opencode: command = "opencode --session=\(quote(session.sessionID)) -- \(quote(session.cwd))"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    #if AGENT_UI_PREVIEW
    func setPreviewSessions(_ sessions: [AgentSession]) { self.sessions = sessions }
    #endif
}

struct AgentIntegrationState: Decodable {
    var provider: String
    var installed: Bool
    var message: String
}

@MainActor
final class AgentIntegrationSetup: ObservableObject {
    @Published private(set) var states: [AgentProvider: AgentIntegrationState] = [:]
    @Published private(set) var busy: Set<AgentProvider> = []
    private let queue = DispatchQueue(label: "app.broschy.agent-setup", qos: .utility)

    func refresh() { AgentProvider.allCases.forEach { run("status", provider: $0) } }

    func run(_ action: String, provider: AgentProvider) {
        guard !busy.contains(provider) else { return }
        guard let resources = Bundle.main.resourceURL,
              let executable = Bundle.main.executableURL else { return }
        let script = resources.appendingPathComponent("Integrations/agent-integrations.py")
        let template = resources.appendingPathComponent("Integrations/opencode/broschy.js")
        let cli = executable.deletingLastPathComponent().appendingPathComponent("broschy-cli")
        guard FileManager.default.fileExists(atPath: script.path) else {
            states[provider] = .init(provider: provider.rawValue, installed: false,
                                     message: "Build and launch Broschy.app to connect tools.")
            return
        }
        busy.insert(provider)
        queue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, action, "--provider", provider.rawValue,
                                 "--cli-path", cli.path, "--template-path", template.path]
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var result: AgentIntegrationState
            do {
                try process.run()
                // The bundled installer only reads bounded local files. Terminate an unexpected stall.
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                guard data.count <= 32_768 else { throw CocoaError(.fileReadCorruptFile) }
                result = try JSONDecoder().decode(AgentIntegrationState.self, from: data)
            } catch {
                result = .init(provider: provider.rawValue, installed: false,
                               message: "Setup could not finish. Python 3 is required; see the integration guide.")
            }
            DispatchQueue.main.async {
                self?.states[provider] = result
                self?.busy.remove(provider)
            }
        }
    }
}

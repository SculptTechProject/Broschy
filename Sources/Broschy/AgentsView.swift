import AgentBridge
import AppKit
import SwiftUI

extension AgentStatus {
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsAttention: return "Needs attention"
        case .ready: return "Ready to review"
        case .error: return "Error"
        case .closed: return "Ended"
        case .unknown: return "Status unknown"
        }
    }
    var tint: Color {
        switch self {
        case .working: return Ink.success
        case .needsAttention: return Ink.primary
        case .ready: return Ink.success
        case .error: return Ink.failure
        default: return Ink.muted
        }
    }
    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .needsAttention: return "hand.raised.fill"
        case .ready: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        default: return "circle"
        }
    }
}

private extension AgentProvider {
    var monogram: String {
        switch self {
        case .codex: return "C"
        case .claude: return "✳︎"
        case .opencode: return "o"
        }
    }
}

struct AgentMark: View {
    let provider: AgentProvider
    var body: some View {
        Text(provider.monogram)
            .font(.system(size: provider == .claude ? 22 : 16, weight: .semibold, design: .rounded))
            .frame(width: 34, height: 34)
            .background(Ink.selection, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.separator, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct AgentsView: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject var state: PanelState
    @StateObject private var setup = AgentIntegrationSetup()
    @State private var showsSetup = false
    @State private var copiedID: String?
    @State private var copyGeneration = 0
    @Environment(\.flowReduceMotion) var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(monitor.workingCount > 0 ? Ink.success : Ink.muted.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(monitor.workingCount > 0 ? "\(monitor.workingCount) working" : "Agent activity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.muted)
                Spacer()
                Button { showsSetup = true } label: {
                    Label("Connections", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(QuietButtonStyle())
                .popover(isPresented: $showsSetup, arrowEdge: .bottom) {
                    AgentConnectionsView(setup: setup, monitor: monitor)
                }
            }
            .padding(.top, 12)

            if let error = monitor.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Ink.failure)
            }
            if monitor.visibleSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !monitor.attention.isEmpty {
                            sectionLabel("Needs you", count: monitor.needsYouCount, tint: Ink.primary)
                            ForEach(monitor.attention) { row($0) }
                        }
                        if !monitor.errors.isEmpty {
                            sectionLabel("Errors", count: monitor.errors.count, tint: Ink.failure)
                                .padding(.top, monitor.attention.isEmpty ? 0 : 9)
                            ForEach(monitor.errors) { row($0) }
                        }
                        if !monitor.readyResponses.isEmpty {
                            sectionLabel("Ready to review", count: monitor.readyResponses.count, tint: Ink.success)
                                .padding(.top, monitor.attention.isEmpty && monitor.errors.isEmpty ? 0 : 9)
                            ForEach(monitor.readyResponses) { row($0) }
                        }
                        if !monitor.others.isEmpty {
                            sectionLabel("Sessions", count: monitor.others.count, tint: Ink.muted)
                                .padding(.top, monitor.attention.isEmpty && monitor.errors.isEmpty && monitor.readyResponses.isEmpty ? 0 : 9)
                            ForEach(monitor.others) { row($0) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.bottom, 10)
        .onAppear { setup.refresh() }
        .onChange(of: showsSetup) { _, presented in state.hasAgentPopover = presented }
        .onChange(of: state.expanded) { _, expanded in if !expanded { showsSetup = false } }
        .onDisappear { showsSetup = false; state.hasAgentPopover = false }
    }

    private var hasConnections: Bool { setup.states.values.contains { $0.installed } }

    private var emptyState: some View {
        VStack(spacing: 10) {
            HStack(spacing: -5) {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    AgentMark(provider: provider)
                        .rotationEffect(.degrees(provider == .codex ? -10 : provider == .opencode ? 10 : 0))
                        .offset(y: provider == .claude ? -6 : 0)
                }
            }
            .padding(.bottom, 3)
            Text(hasConnections ? "Waiting for your agents." : "Your agents, in view.")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(hasConnections ? "Start a new session in a connected tool.\nYour activity will appear here." : "See who’s working, waiting for you,\nand ready for a review.")
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center).lineSpacing(3)
            Button { showsSetup = true } label: {
                Text(hasConnections ? "Manage connections" : "Connect your tools").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 18).frame(height: 34)
            }
                .buttonStyle(FlowButtonStyle(primary: true)).padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionLabel(_ title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(tint.opacity(0.10), in: Capsule())
        }
        .foregroundStyle(tint).padding(.vertical, 4)
    }

    private func row(_ session: AgentSession) -> some View {
        let status = session.effectiveStatus()
        return HStack(spacing: 10) {
            AgentMark(provider: session.provider)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if session.parentSessionID != nil {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(Ink.muted)
                            .help("Subagent session")
                    }
                    Spacer(minLength: 0)
                    Text(session.updatedAt, style: .relative)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Ink.muted)
                        .lineLimit(1).fixedSize()
                }
                HStack(spacing: 5) {
                    Text(session.provider.displayName).foregroundStyle(Ink.muted)
                    Text("·").foregroundStyle(Ink.muted)
                    Text(status.label).foregroundStyle(status.tint)
                }
                .font(.system(size: 10)).lineLimit(1)
                if status == .needsAttention || status == .unknown || status == .error {
                    Text(status == .unknown ? "Activity not confirmed · check your agent" : (status == .error && session.needsAttention() ? "Response needed in your agent" : session.detail))
                        .font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(1)
                }
            }
            Menu {
                Button(copiedID == session.id ? "Resume command copied" : "Copy resume command") {
                    monitor.copyResumeCommand(session)
                    copiedID = session.id
                    copyGeneration += 1
                    let generation = copyGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if copyGeneration == generation { copiedID = nil }
                    }
                }
                Button("Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true)) }
                if status == .ready || status == .error {
                    Divider()
                    Button("Mark reviewed") { monitor.acknowledge(session) }
                        .disabled(session.acknowledgedAt != nil || session.needsAttention()
                                  || (status == .ready && !session.pendingRequestIDs.isEmpty))
                }
            } label: {
                Image(systemName: copiedID == session.id ? "checkmark" : status.symbol)
                    .foregroundStyle(status.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: state.expanded && status == .working && !reduceMotion)
                    .font(.system(size: 15)).frame(width: 28, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(session.provider.displayName), \(session.title), \(status.label)")
            .help("Session actions")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.separator).frame(height: 0.5).padding(.leading, 44) }
    }
}

struct AgentConnectionsView: View {
    @ObservedObject var setup: AgentIntegrationSetup
    @ObservedObject var monitor: AgentMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Connect your tools").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Local status from your coding agents.")
                    .font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                let state = setup.states[provider]
                let hasEvents = monitor.sessions.contains { $0.provider == provider && $0.updatedAt > Date().addingTimeInterval(-86400) }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        AgentMark(provider: provider)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.displayName).font(.system(size: 12, weight: .semibold))
                            Text(state?.installed == true ? (hasEvents ? "Events received" : "Configured · awaiting events") : "Not connected")
                                .font(.system(size: 10)).foregroundStyle(Ink.muted)
                        }
                        Spacer()
                        Button(state?.installed == true ? "Disconnect" : "Connect") {
                            setup.run(state?.installed == true ? "uninstall" : "install", provider: provider)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(setup.busy.contains(provider))
                    }
                    if let state, !state.message.isEmpty {
                        Text(state.message).font(.system(size: 10)).foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Text("Restart your agent after connecting. In Codex, review Broschy’s hooks with /hooks if prompted. Existing sessions may need a new turn to appear.")
                .font(.system(size: 11)).foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Integration guide") {
                if let guide = Bundle.main.resourceURL?.appendingPathComponent("Integrations/Guide.md") { NSWorkspace.shared.open(guide) }
            }.buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(20).frame(width: 350)
        .onAppear { setup.refresh() }
    }
}

struct CompactAgentsLeading: View {
    @ObservedObject var monitor: AgentMonitor
    let attention: [AgentSession]
    let reduceMotion: Bool
    let isVisible: Bool
    var height: CGFloat = 38
    private var requests: [AgentSession] { attention.filter { $0.needsAttention() } }
    private var hasError: Bool { attention.contains { $0.attentionKind() == .error } }
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: !requests.isEmpty ? "hand.raised.fill" : hasError ? "exclamationmark.circle.fill" : "circle.dotted")
                .font(.system(size: 16, weight: .medium))
                .symbolEffect(.pulse, options: .repeating, isActive: isVisible && !reduceMotion && monitor.hasCompactActivity)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agents").font(.system(size: 10, weight: .semibold))
                if height >= 28 {
                    Text("\(monitor.workingCount) working").font(.system(size: 9)).foregroundStyle(Ink.muted)
                }
            }
        }
        .frame(height: height)
        .foregroundStyle(!requests.isEmpty ? Ink.primary : hasError ? Ink.failure : Ink.success)
        .accessibilityHidden(true)
    }
}

struct CompactAgentsTrailing: View {
    @ObservedObject var monitor: AgentMonitor
    let attention: [AgentSession]
    var height: CGFloat = 38
    private var requests: [AgentSession] { attention.filter { $0.needsAttention() } }
    private var errors: [AgentSession] { attention.filter { $0.attentionKind() == .error } }
    private var label: String {
        if !requests.isEmpty { return "\(requests.count) need\(requests.count == 1 ? "s" : "") you" }
        if !errors.isEmpty { return "\(errors.count) error\(errors.count == 1 ? "" : "s")" }
        return "In progress"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(!requests.isEmpty ? Ink.primary : !errors.isEmpty ? Ink.failure : Ink.text)
            if height >= 28 {
                Text(requests.first?.title ?? errors.first?.title ?? monitor.visibleSessions.first(where: { $0.effectiveStatus() == .working })?.title ?? "Agents")
                    .font(.system(size: 9)).foregroundStyle(Ink.muted)
            }
        }
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

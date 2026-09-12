import AppKit
import SwiftUI

extension BuildWatchRunState {
    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "circle.dotted"
        case .waiting: return "hand.raised"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .skipped, .neutral: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }
    var tint: Color {
        switch self {
        case .success: return Ink.success
        case .failure: return Ink.failure
        case .queued, .running, .waiting: return Ink.primary
        default: return Ink.muted
        }
    }
}

extension BuildWatchController {
    var compactRun: BuildWatchRun? {
        guard isLive else { return nil }
        if let completion = recentCompletion, (0..<12).contains(Date().timeIntervalSince(completion.observedAt)) {
            return completion.run
        }
        return runs.first(where: \.isActive)
    }
}

struct SignalsHubView: View {
    @ObservedObject var store: FlowStore
    @ObservedObject var state: PanelState
    @ObservedObject var builds: BuildWatchController

    var body: some View {
        VStack(spacing: 4) {
            Picker("Signal source", selection: $state.signalPage) {
                Text("Build Watch").tag(0)
                Text("Commands").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(.top, 12)
            if state.signalPage == 0 { BuildWatchView(builds: builds) }
            else { SignalsView(store: store) }
        }
    }
}

struct BuildWatchView: View {
    @ObservedObject var builds: BuildWatchController
    @State private var editingTarget = false
    @State private var repository = ""
    @State private var branch = ""
    @Environment(\.flowReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !builds.isEnabled || editingTarget { setup }
            else { connected }
        }
        .onAppear { prefill() }
        .onChange(of: builds.target) { _, _ in prefill() }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your next green build.")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Spacer()
                    if editingTarget {
                        Button("Cancel") { editingTarget = false }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                Text("Watch GitHub Actions for a repository or pull request.")
                    .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 7) {
                    TextField("owner/repository or GitHub PR URL", text: $repository)
                        .accessibilityLabel("GitHub repository or pull request")
                    TextField("Branch · blank uses the default", text: $branch)
                        .accessibilityLabel("Branch, optional for repositories")
                        .disabled(repository.contains("/pull/"))
                }
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .onSubmit { connect() }
                if let error = builds.inputError {
                    Text(error).font(.system(size: 10)).foregroundStyle(Ink.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(action: connect) {
                        Label(editingTarget ? "Save watch" : "Watch builds", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).frame(height: 32)
                    }
                    .buttonStyle(FlowButtonStyle(primary: true))
                    .disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Uses GitHub CLI (gh)\nand its existing sign-in.")
                        .font(.system(size: 10)).foregroundStyle(Ink.muted)
                }
                .padding(.top, 1)
            }
            .padding(.vertical, 12)
        }.scrollIndicators(.hidden)
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(builds.target?.displayName ?? "Build Watch")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .help(builds.target?.displayName ?? "")
                    HStack(spacing: 4) {
                        Circle().fill(builds.isLive ? Ink.success : Ink.muted).frame(width: 4, height: 4)
                        Text(connectionDetail).font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { builds.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 28)
                }
                .buttonStyle(QuietButtonStyle()).disabled(builds.isRefreshing)
                .help("Refresh builds").accessibilityLabel("Refresh builds")
                Menu {
                    Button("Change repository…") { prefill(); editingTarget = true }
                    Button("Open on GitHub") {
                        if let url = builds.target?.webURL { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Disconnect Build Watch") { builds.disconnect() }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Build Watch options").accessibilityLabel("Build Watch options")
            }
            if let error = builds.errorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.failure)
                    Text(error).font(.system(size: 10)).foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.inset, in: RoundedRectangle(cornerRadius: 9))
            }
            if builds.runs.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: builds.isRefreshing ? "arrow.triangle.2.circlepath" : "checklist")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(Ink.primary)
                        .symbolEffect(.pulse, options: .repeating, isActive: builds.isRefreshing && !reduceMotion)
                    Text(builds.isRefreshing ? "Checking GitHub…" : builds.status == .failure ? "Waiting for a connection." : "No workflow runs yet.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    if builds.status != .failure {
                        Text(builds.isRefreshing ? "Your workflow status will appear here." : "Push a change to this branch to get started.")
                            .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(builds.runs) { run in
                            row(run)
                            if run.id != builds.runs.last?.id { Rectangle().fill(Ink.separator).frame(height: 0.5) }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.padding(.top, 9).padding(.bottom, 8)
    }

    private func row(_ run: BuildWatchRun) -> some View {
        let stale = !builds.isLive
        let color = stale ? Ink.muted : run.state.tint
        // GitHub's updated_at is metadata freshness, not an execution duration.
        // A relative date keeps ticking even after the workflow has completed.
        let updateTime = run.updatedAt.formatted(.dateTime.month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        let fullUpdateTime = run.updatedAt.formatted(.dateTime.year().month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Locale(identifier: "en_GB")))
        return Button { NSWorkspace.shared.open(run.htmlURL) } label: {
            HStack(spacing: 10) {
                Image(systemName: stale && run.isActive ? "questionmark.circle" : run.state.symbol)
                    .font(.system(size: 15)).foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(run.headBranch) · \(run.headSHA.prefix(7))")
                        .font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(stale && run.isActive ? "Last seen active" : run.statusText)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(color).lineLimit(1)
                    Text("Updated \(updateTime)")
                        .font(.system(size: 9)).foregroundStyle(Ink.muted).lineLimit(1)
                }
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Ink.muted)
            }
            .padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .help("\(run.name) · \(run.statusText) · Last GitHub update: \(fullUpdateTime) · Open workflow on GitHub")
        .accessibilityLabel("\(run.name), \(stale && run.isActive ? "last seen active" : run.statusText). Updated \(fullUpdateTime). Open workflow on GitHub.")
    }

    private var connectionDetail: String {
        if builds.isRefreshing { return "Checking GitHub…" }
        if !builds.isLive {
            return builds.lastUpdatedAt == nil ? "Not connected · retrying automatically" : "Last fetched results · reconnecting"
        }
        return "\(builds.resolvedBranch ?? "Default branch") · checks every 30 seconds"
    }
    private func prefill() {
        repository = builds.target?.repositoryInput ?? ""
        branch = builds.target?.branch ?? ""
    }
    private func connect() {
        if builds.connect(repository, branch: branch) { editingTarget = false }
    }
}

struct CompactBuildLeading: View {
    @ObservedObject var builds: BuildWatchController
    let isVisible: Bool
    let reduceMotion: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: builds.compactRun?.state.symbol ?? "checklist")
                .font(.system(size: 16, weight: .medium))
                .symbolEffect(.pulse, options: .repeating,
                              isActive: isVisible && !reduceMotion && builds.activeCount > 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("Build Watch").font(.system(size: 10, weight: .semibold))
                Text(builds.compactRun?.statusText ?? "GitHub Actions")
                    .font(.system(size: 9)).foregroundStyle(Ink.muted).lineLimit(1)
            }
        }
        .foregroundStyle(builds.compactRun?.state.tint ?? Ink.muted)
        .padding(.horizontal, 8).accessibilityHidden(true)
    }
}

struct CompactBuildTrailing: View {
    @ObservedObject var builds: BuildWatchController
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(builds.compactRun?.name ?? "GitHub Actions")
                .font(.system(size: 10, weight: .semibold))
            Text(builds.target?.repository ?? "Build Watch")
                .font(.system(size: 9)).foregroundStyle(Ink.muted)
        }
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13)
        .accessibilityHidden(true)
    }
}

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
    @ObservedObject var builds: BuildWatchMonitor

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
    @ObservedObject var builds: BuildWatchMonitor
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var showingEditor = false
    @State private var repository = ""
    @State private var branch = ""
    @State private var formError: String?
    @FocusState private var repositoryFocused: Bool

    var body: some View {
        Group {
            if showingEditor {
                editor
            } else if let selectedID, let item = builds.repository(selectedID) {
                BuildWatchDetailView(builds: item.controller,
                    back: { self.selectedID = nil },
                    edit: { beginEditing(item) },
                    remove: {
                        builds.remove(item.id)
                        self.selectedID = nil
                    })
                    .id(item.id)
            } else if builds.repositories.isEmpty {
                emptyState
            } else {
                watchlist
            }
        }
        .onChange(of: builds.repositories.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if let editingID, !ids.contains(editingID) { cancelEditing() }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your builds, in one place.")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("Follow GitHub Actions across repositories, branches, and pull requests. Open a repository to see its workflows.")
                    .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: beginAdding) {
                    Label("Add repository", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(FlowButtonStyle(primary: true))
                Text("Uses GitHub CLI (gh) and its existing sign-in.")
                    .font(.system(size: 10)).foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
    }

    private var watchlist: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repositories").font(.system(size: 13, weight: .semibold))
                    Text("\(builds.repositories.count) watched · \(builds.activeCount) active")
                        .font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: beginAdding) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 28)
                }
                .buttonStyle(FlowButtonStyle(primary: false))
                .accessibilityLabel("Add repository")
                Button { builds.refreshAll() } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                        .font(.system(size: 11)).padding(.horizontal, 5).frame(height: 28)
                }
                .buttonStyle(QuietButtonStyle()).disabled(builds.isRefreshing)
                .help(builds.isRefreshing ? "Checking watched repositories…" : "Refresh all watched repositories")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(builds.repositories) { item in
                        BuildWatchRepositoryRow(builds: item.controller) { selectedID = item.id }
                        if item.id != builds.repositories.last?.id {
                            Rectangle().fill(Ink.separator).frame(height: 0.5)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.top, 8).padding(.bottom, 8)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(editingID == nil ? "Add repository" : "Edit watch")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Spacer()
                    Button("Cancel", action: cancelEditing)
                        .buttonStyle(.link).font(.system(size: 11))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository or pull request").font(.system(size: 11, weight: .medium))
                    TextField("owner/repository or GitHub PR URL", text: $repository)
                        .accessibilityLabel("GitHub repository or pull request")
                        .focused($repositoryFocused)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(isPullRequest ? "Branch from pull request" : "Branch (optional)")
                        .font(.system(size: 11, weight: .medium))
                    TextField(isPullRequest ? "Follows the pull request’s head commit" : "Blank uses the default branch", text: $branch)
                        .accessibilityLabel("Branch, optional for repositories")
                        .disabled(isPullRequest)
                }
                .foregroundStyle(isPullRequest ? Ink.muted : Ink.text)
                if let error = formError {
                    Label {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.system(size: 10)).foregroundStyle(Ink.failure)
                    .accessibilityLabel("Could not save watch. \(error)")
                }
                HStack(spacing: 12) {
                    Button(action: save) {
                        Text(editingID == nil ? "Add to watchlist" : "Save changes")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).frame(height: 32)
                    }
                    .buttonStyle(FlowButtonStyle(primary: true))
                    .disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Uses your GitHub CLI sign-in.")
                        .font(.system(size: 10)).foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 12))
            .onSubmit(save)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .onAppear { repositoryFocused = true }
        .onChange(of: repository) { _, _ in
            formError = nil
            if isPullRequest { branch = "" }
        }
        .onChange(of: branch) { _, _ in formError = nil }
    }

    private var isPullRequest: Bool { repository.contains("/pull/") }

    private func beginAdding() {
        editingID = nil
        repository = ""
        branch = ""
        formError = nil
        showingEditor = true
    }

    private func beginEditing(_ item: BuildWatchRepository) {
        editingID = item.id
        repository = item.controller.target?.repositoryInput ?? ""
        branch = item.controller.target?.branch ?? ""
        formError = nil
        showingEditor = true
    }

    private func cancelEditing() {
        repositoryFocused = false
        showingEditor = false
        editingID = nil
        formError = nil
    }

    private func save() {
        let saved: Bool
        if let editingID {
            saved = builds.update(editingID, input: repository, branch: isPullRequest ? "" : branch)
        } else {
            saved = builds.add(repository, branch: isPullRequest ? "" : branch)
            if saved { selectedID = nil }
        }
        if saved { cancelEditing() }
        else { formError = builds.inputError ?? "Could not save this watch. Check the repository and try again." }
    }
}

private struct BuildWatchRepositoryRow: View {
    @ObservedObject var builds: BuildWatchController
    let open: () -> Void

    private var summary: String {
        if let error = builds.errorMessage { return error }
        if builds.isRefreshing && builds.runs.isEmpty { return "Checking GitHub…" }
        if !builds.isLive {
            return builds.lastUpdatedAt == nil ? "Waiting for a connection" : "Last fetched results · reconnecting"
        }
        if builds.activeCount > 0 {
            let count = builds.activeCount
            let name = builds.runs.first(where: \.isActive)?.name ?? "GitHub Actions"
            return "\(count) active \(count == 1 ? "workflow" : "workflows") · \(name)"
        }
        guard let run = builds.runs.first else { return "No workflow runs yet" }
        return "\(run.name) · \(run.statusText)"
    }

    private var symbol: String {
        if builds.errorMessage != nil { return "exclamationmark.triangle" }
        guard builds.isLive else { return builds.isRefreshing ? "arrow.clockwise" : "questionmark.circle" }
        return builds.runs.first(where: \.isActive)?.state.symbol ?? builds.runs.first?.state.symbol ?? "checklist"
    }

    private var tint: Color {
        if builds.errorMessage != nil { return Ink.failure }
        guard builds.isLive else { return Ink.muted }
        return builds.runs.first(where: \.isActive)?.state.tint ?? builds.runs.first?.state.tint ?? Ink.muted
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint)
                    .frame(width: 19, height: 19).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(builds.target?.displayName ?? "Repository")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(BuildWatchPresentation.scope(builds)).lineLimit(1)
                        Spacer(minLength: 2)
                        if let updated = builds.lastUpdatedAt {
                            Text("Checked \(BuildWatchPresentation.shortDate(updated))")
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .font(.system(size: 9)).foregroundStyle(Ink.muted)
                    Text(summary).font(.system(size: 10)).foregroundStyle(builds.errorMessage == nil ? Ink.muted : Ink.failure)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.muted).padding(.top, 5)
            }
            .padding(.horizontal, 4).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .help("\(builds.target?.displayName ?? "Repository") · \(BuildWatchPresentation.scope(builds)) · \(summary)")
        .accessibilityLabel("\(builds.target?.displayName ?? "Repository"), \(BuildWatchPresentation.scope(builds)). \(summary). Show workflows.")
    }
}

private struct BuildWatchDetailView: View {
    @ObservedObject var builds: BuildWatchController
    let back: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    @Environment(\.flowReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(QuietButtonStyle())
                .help("Back to repositories").accessibilityLabel("Back to repositories")
                VStack(alignment: .leading, spacing: 3) {
                    Text(builds.target?.displayName ?? "Build Watch")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(BuildWatchPresentation.scope(builds))
                        .font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(1)
                }
                .help(builds.target?.displayName ?? "Build Watch")
                Spacer(minLength: 4)
                Button { builds.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 28)
                }
                .buttonStyle(QuietButtonStyle()).disabled(builds.isRefreshing)
                .help("Refresh this repository").accessibilityLabel("Refresh this repository")
                Menu {
                    Button("Edit watch…", action: edit)
                    Button("Open on GitHub") {
                        if let url = builds.target?.webURL { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Remove from watchlist", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Repository options").accessibilityLabel("Repository options")
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
                        Text(builds.isRefreshing ? "Your workflow status will appear here." : "New runs for this watch will appear here.")
                            .font(.system(size: 11)).foregroundStyle(Ink.muted)
                            .multilineTextAlignment(.center)
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
            HStack(spacing: 4) {
                Circle().fill(builds.isLive ? Ink.success : Ink.muted).frame(width: 4, height: 4)
                Text(connectionDetail).font(.system(size: 9)).foregroundStyle(Ink.muted).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 9).padding(.bottom, 8)
    }

    private func row(_ run: BuildWatchRun) -> some View {
        let stale = !builds.isLive
        let color = stale ? Ink.muted : run.state.tint
        // updated_at is fixed GitHub metadata, never an execution duration.
        let updateTime = BuildWatchPresentation.shortDate(run.updatedAt)
        let fullUpdateTime = run.updatedAt.formatted(.dateTime.year().month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Locale(identifier: "en_GB")))
        return Button { NSWorkspace.shared.open(run.htmlURL) } label: {
            HStack(spacing: 9) {
                Image(systemName: stale && run.isActive ? "questionmark.circle" : run.state.symbol)
                    .font(.system(size: 15)).foregroundStyle(color)
                    .frame(width: 30, height: 32)
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
                .fixedSize(horizontal: true, vertical: false)
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
        return "Checks every 30 seconds"
    }
}

private enum BuildWatchPresentation {
    @MainActor static func scope(_ builds: BuildWatchController) -> String {
        if let number = builds.target?.pullRequest {
            return "PR #\(number)" + (builds.resolvedBranch.map { " · \($0)" } ?? " · head commit")
        }
        return builds.resolvedBranch ?? builds.target?.branch ?? "Default branch"
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
    }
}

struct CompactBuildLeading: View {
    @ObservedObject var builds: BuildWatchMonitor
    let isVisible: Bool
    let reduceMotion: Bool
    var height: CGFloat = 38

    private var run: BuildWatchRun? { builds.compactRepository?.controller.compactRun }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: run?.state.symbol ?? "checklist")
                .font(.system(size: 16, weight: .medium))
                .symbolEffect(.pulse, options: .repeating,
                              isActive: isVisible && !reduceMotion && run?.isActive == true)
            VStack(alignment: .leading, spacing: 1) {
                Text(builds.activeCount > 0 ? "\(builds.activeCount) active" : "Build Watch")
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                if height >= 28 {
                    Text(run?.statusText ?? "GitHub Actions")
                        .font(.system(size: 9)).foregroundStyle(Ink.muted).lineLimit(1)
                }
            }
        }
        .frame(height: height)
        .foregroundStyle(run?.state.tint ?? Ink.muted)
        .padding(.horizontal, 8).accessibilityHidden(true)
    }
}

struct CompactBuildTrailing: View {
    @ObservedObject var builds: BuildWatchMonitor
    var height: CGFloat = 38

    private var selected: BuildWatchController? { builds.compactRepository?.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(selected?.target?.repository ?? "GitHub Actions")
                .font(.system(size: 10, weight: .semibold))
            if height >= 28 {
                Text(selected?.compactRun?.name ?? "Build Watch")
                    .font(.system(size: 9)).foregroundStyle(Ink.muted)
            }
        }
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

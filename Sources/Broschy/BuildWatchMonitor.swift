import Combine
import Foundation

struct BuildWatchRepository: Identifiable {
    let id: UUID
    let controller: BuildWatchController
}

/// Owns independent watches; each controller keeps its own poll, cancellation,
/// freshness, baseline, backoff, and completion history.
@MainActor
final class BuildWatchMonitor: ObservableObject {
    @Published private(set) var repositories: [BuildWatchRepository] = []
    @Published private(set) var inputError: String?

    private static let repositoriesKey = "buildWatchRepositories"
    private let defaults: UserDefaults
    private let startTicker: Bool
    private let clock: () -> Date
    private let perform: (BuildWatchRequest, BuildWatchCancellation) -> BuildWatchOutcome
    private var subscriptions: [UUID: AnyCancellable] = [:]

    init(defaults: UserDefaults = .standard, startTicker: Bool = true,
         clock: @escaping () -> Date = Date.init,
         perform: @escaping (BuildWatchRequest, BuildWatchCancellation) -> BuildWatchOutcome = BuildWatchTransport.fetch) {
        self.defaults = defaults
        self.startTicker = startTicker
        self.clock = clock
        self.perform = perform

        // Presence, including an empty or malformed list, is the migration
        // marker. Removing the final watch must never resurrect a legacy one.
        if defaults.object(forKey: Self.repositoriesKey) == nil {
            let legacy = BuildWatchController(defaults: defaults, startTicker: false, clock: clock, perform: perform)
            var ids: [String] = []
            if legacy.isEnabled, legacy.target != nil {
                let id = UUID()
                legacy.copySavedConfiguration(to: Self.namespace(for: id))
                ids = [id.uuidString]
            }
            defaults.set(ids, forKey: Self.repositoriesKey)
        }

        var usedIDs = Set<UUID>()
        var scopes = Set<Scope>()
        for raw in defaults.stringArray(forKey: Self.repositoriesKey) ?? [] {
            guard let id = UUID(uuidString: raw), usedIDs.insert(id).inserted else { continue }
            let controller = makeController(id: id)
            guard let target = controller.target, scopes.insert(Scope(target)).inserted else { continue }
            let repository = BuildWatchRepository(id: id, controller: controller)
            repositories.append(repository)
            observe(repository)
            if startTicker { controller.startMonitoring() }
        }
        persistRepositories()
    }

    var activeCount: Int {
        let now = clock()
        return repositories.reduce(0) { total, repository in
            total + (isLive(repository.controller, at: now) ? repository.controller.runs.filter(\.isActive).count : 0)
        }
    }

    var isRefreshing: Bool { repositories.contains { $0.controller.isRefreshing } }

    var compactRepository: BuildWatchRepository? {
        let now = clock()
        let live = repositories.filter { isLive($0.controller, at: now) }
        let completed = live.compactMap { repository -> (BuildWatchRepository, Date)? in
            guard let completion = repository.controller.recentCompletion,
                  (0..<12).contains(now.timeIntervalSince(completion.observedAt)) else { return nil }
            return (repository, completion.observedAt)
        }
        if let latest = completed.max(by: { $0.1 < $1.1 }) { return latest.0 }
        return live.compactMap { repository -> (BuildWatchRepository, Date)? in
            guard let updatedAt = repository.controller.runs.filter(\.isActive).map(\.updatedAt).max() else { return nil }
            return (repository, updatedAt)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    @discardableResult
    func add(_ input: String, branch: String = "") -> Bool {
        guard let target = parse(input, branch: branch) else { return false }
        guard !contains(target) else { inputError = "This repository and branch or pull request are already being watched."; return false }
        let id = UUID()
        let controller = makeController(id: id)
        if startTicker { controller.startMonitoring() }
        guard controller.connect(input, branch: branch) else { inputError = controller.inputError; return false }
        let repository = BuildWatchRepository(id: id, controller: controller)
        repositories.append(repository)
        observe(repository)
        persistRepositories()
        inputError = nil
        return true
    }

    @discardableResult
    func update(_ id: UUID, input: String, branch: String = "") -> Bool {
        guard let repository = repository(id) else { inputError = "This watch is no longer available."; return false }
        guard let target = parse(input, branch: branch) else { return false }
        guard !contains(target, excluding: id) else { inputError = "This repository and branch or pull request are already being watched."; return false }
        if let existing = repository.controller.target, Scope(existing) == Scope(target), repository.controller.isEnabled {
            inputError = nil
            return true
        }
        guard repository.controller.connect(input, branch: branch) else { inputError = repository.controller.inputError; return false }
        inputError = nil
        return true
    }

    func remove(_ id: UUID) {
        guard let repository = repository(id) else { return }
        repository.controller.disconnect()
        subscriptions.removeValue(forKey: id)?.cancel()
        repositories.removeAll { $0.id == id }
        persistRepositories()
        repository.controller.removeSavedConfiguration()
        inputError = nil
    }

    func refreshAll() { repositories.forEach { $0.controller.refresh() } }

    func repository(_ id: UUID) -> BuildWatchRepository? { repositories.first { $0.id == id } }

    private func makeController(id: UUID) -> BuildWatchController {
        BuildWatchController(defaults: defaults, storageNamespace: Self.namespace(for: id),
                             startTicker: false, clock: clock, perform: perform)
    }

    private func observe(_ repository: BuildWatchRepository) {
        let id = repository.id
        subscriptions[id] = repository.controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.repository(id) != nil else { return }
                // Relay only after the child's @Published assignment has settled.
                self.objectWillChange.send()
            }
    }

    private func parse(_ input: String, branch: String) -> BuildWatchTarget? {
        do { return try BuildWatchTarget.parse(input, branch: branch) }
        catch { inputError = (error as? BuildWatchError ?? .invalidTarget).message; return nil }
    }

    private func contains(_ target: BuildWatchTarget, excluding id: UUID? = nil) -> Bool {
        repositories.contains { $0.id != id && $0.controller.target.map { Scope($0) == Scope(target) } == true }
    }

    private func isLive(_ controller: BuildWatchController, at now: Date) -> Bool {
        guard controller.isEnabled, controller.isLive, let updatedAt = controller.lastUpdatedAt else { return false }
        return (0...75).contains(now.timeIntervalSince(updatedAt))
    }

    private func persistRepositories() { defaults.set(repositories.map { $0.id.uuidString }, forKey: Self.repositoriesKey) }

    private static func namespace(for id: UUID) -> String { "buildWatchRepository." + id.uuidString.lowercased() }

    /// Keep branch case and nil distinct from a literal "default" branch while
    /// preserving the legacy completion hashes inside each isolated controller.
    private struct Scope: Hashable {
        let owner: String
        let repository: String
        let branch: String?
        let pullRequest: Int?
        init(_ target: BuildWatchTarget) {
            owner = target.owner.lowercased(); repository = target.repository.lowercased()
            branch = target.branch; pullRequest = target.pullRequest
        }
    }
}

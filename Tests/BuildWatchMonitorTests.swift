import Combine
import Foundation

/// Isolated preferences and injected responses only; no GitHub requests or
/// changes to the signed-in account or the user's watchlist.
@main
struct BuildWatchMonitorTests {
    static let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    @MainActor static func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("The fixture worker did not finish")
    }

    static func run(_ repository: String, id: Int64, status: BuildWatchRunStatus = .inProgress,
                    conclusion: BuildWatchConclusion? = nil, updatedAt: Date = epoch,
                    attempt: Int = 1, branch: String = "main") -> BuildWatchRun {
        .init(id: id, name: "CI", headBranch: branch, headSHA: String(repeating: "a", count: 40),
              htmlURL: URL(string: "https://github.com/owner/\(repository)/actions/runs/\(id)")!,
              createdAt: epoch, updatedAt: updatedAt, status: status, conclusion: conclusion, attempt: attempt)
    }

    static func snapshot(_ runs: [BuildWatchRun], branch: String = "main") -> BuildWatchOutcome {
        .success(.init(runs: runs, resolvedBranch: branch, scopeIdentity: branch))
    }

    @MainActor static func main() async throws {
        var suites: [String] = []
        func preferences(_ label: String) -> UserDefaults {
            let suite = "app.broschy.watch-monitor-tests." + label + "." + UUID().uuidString
            suites.append(suite)
            return UserDefaults(suiteName: suite)!
        }
        defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }

        let legacyDefaults = preferences("migration")
        let legacyTarget = try BuildWatchTarget.parse("owner/legacy", branch: "main")
        legacyDefaults.set(try JSONEncoder().encode(legacyTarget), forKey: "buildWatchTarget")
        legacyDefaults.set(true, forKey: "buildWatchEnabled")
        legacyDefaults.set([legacyTarget.identity + ":7:1", "PRIVATE_INVALID_FIXTURE"], forKey: "buildWatchSeenCompletions")
        let migrationTransport = WatchMonitorTransport()
        let migrated = BuildWatchMonitor(defaults: legacyDefaults, startTicker: false, clock: { epoch }, perform: migrationTransport.perform)
        precondition(migrated.repositories.count == 1 && migrated.repositories[0].controller.target == legacyTarget)
        precondition(migrated.repositories[0].controller.isEnabled && migrationTransport.count == 0,
                     "Migration must retain opt-in without starting a disabled test ticker")
        let migratedID = migrated.repositories[0].id
        migrationTransport.enqueue("owner/legacy", branch: "main", snapshot([run("legacy", id: 7)]))
        migrated.refreshAll(); await eventually { !migrated.isRefreshing }
        migrationTransport.enqueue("owner/legacy", branch: "main", snapshot([run("legacy", id: 7, status: .completed, conclusion: .success)]))
        migrated.refreshAll(); await eventually { !migrated.isRefreshing }
        precondition(migrated.repositories[0].controller.recentCompletion == nil,
                     "Migration must retain the legacy completion dedup history")
        let legacyReplacement = try BuildWatchTarget.parse("owner/should-not-migrate-again")
        legacyDefaults.set(try JSONEncoder().encode(legacyReplacement), forKey: "buildWatchTarget")
        let relaunchedMigration = BuildWatchMonitor(defaults: legacyDefaults, startTicker: false, clock: { epoch }, perform: migrationTransport.perform)
        precondition(relaunchedMigration.repositories.map(\.id) == [migratedID]
                     && relaunchedMigration.repositories[0].controller.target == legacyTarget,
                     "A second launch must restore the same child namespace instead of importing legacy state again")
        print("PASS: enabled single-watch migration, stable identity, once-only migration, completion history")

        let disabledDefaults = preferences("disabled")
        disabledDefaults.set(try JSONEncoder().encode(legacyTarget), forKey: "buildWatchTarget")
        disabledDefaults.set(false, forKey: "buildWatchEnabled")
        let disabledTransport = WatchMonitorTransport()
        let disabled = BuildWatchMonitor(defaults: disabledDefaults, startTicker: true, perform: disabledTransport.perform)
        precondition(disabled.repositories.isEmpty && disabledTransport.count == 0,
                     "A disconnected legacy watch must not become enabled during migration")
        disabledDefaults.set(true, forKey: "buildWatchEnabled")
        let emptyRestart = BuildWatchMonitor(defaults: disabledDefaults, startTicker: false, perform: disabledTransport.perform)
        precondition(emptyRestart.repositories.isEmpty, "A persisted empty list must not resurrect legacy configuration")
        disabledTransport.enqueue("owner/new", snapshot([]))
        precondition(emptyRestart.add("owner/new"))
        await eventually { !emptyRestart.isRefreshing }
        emptyRestart.remove(emptyRestart.repositories[0].id)
        let afterRemoval = BuildWatchMonitor(defaults: disabledDefaults, startTicker: false, perform: disabledTransport.perform)
        precondition(afterRemoval.repositories.isEmpty && disabledTransport.count == 1)
        print("PASS: disabled legacy stays disabled, removing the last watch persists an empty list")

        let defaults = preferences("editing")
        let transport = WatchMonitorTransport()
        let monitor = BuildWatchMonitor(defaults: defaults, startTicker: false, clock: { epoch }, perform: transport.perform)
        precondition(monitor.repositories.isEmpty && monitor.activeCount == 0 && monitor.compactRepository == nil && transport.count == 0)
        precondition(!monitor.add("https://evil.example/owner/repo") && monitor.inputError != nil && transport.count == 0)
        transport.enqueue("Owner/Repo", snapshot([]))
        precondition(monitor.add("Owner/Repo"))
        await eventually { !monitor.isRefreshing }
        let firstID = monitor.repositories[0].id
        precondition(!monitor.add("https://github.com/owner/REPO") && monitor.repositories.count == 1,
                     "Repository case must not create duplicate watches")
        for branch in ["default", "main", "Main"] {
            transport.enqueue("owner/repo", branch: branch, snapshot([], branch: branch))
            precondition(monitor.add("owner/repo", branch: branch))
            await eventually { !monitor.isRefreshing }
        }
        transport.enqueue("https://github.com/owner/repo/pull/12", snapshot([]))
        precondition(monitor.add("https://github.com/owner/repo/pull/12"))
        await eventually { !monitor.isRefreshing }
        precondition(monitor.repositories.count == 5,
                     "Default branch, literal default, differently cased branches, and a PR are distinct scopes")
        precondition(!monitor.update(firstID, input: "owner/repo", branch: "main"))
        precondition(monitor.repository(firstID)?.controller.target?.branch == nil,
                     "A duplicate edit must preserve the existing watch and its polling state")
        let requestCount = transport.count
        precondition(monitor.update(firstID, input: "OWNER/REPO") && monitor.inputError == nil)
        precondition(transport.count == requestCount, "Saving an unchanged enabled scope must not reset its baseline or refetch")
        precondition(!monitor.update(firstID, input: "owner/other", branch: "bad\nbranch"))
        transport.enqueue("owner/other", snapshot([run("other", id: 9)]))
        precondition(monitor.update(firstID, input: "owner/other"))
        await eventually { !monitor.isRefreshing }
        precondition(monitor.repository(firstID)?.controller.target?.repository == "other" && monitor.activeCount == 1)
        let restored = BuildWatchMonitor(defaults: defaults, startTicker: false, clock: { epoch }, perform: transport.perform)
        precondition(restored.repositories.map(\.id) == monitor.repositories.map(\.id)
                     && restored.repository(firstID)?.controller.target?.repository == "other")
        monitor.remove(firstID)
        let restoredAfterRemoval = BuildWatchMonitor(defaults: defaults, startTicker: false, perform: transport.perform)
        precondition(restoredAfterRemoval.repository(firstID) == nil && restoredAfterRemoval.repositories.count == 4)
        precondition(!monitor.update(firstID, input: "owner/missing") && monitor.inputError != nil)
        let savedKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("buildWatch") }
        precondition(!savedKeys.contains { $0.lowercased().contains("token") || $0.lowercased().contains("runs") },
                     "Only watch configuration and bounded completion identifiers are persisted")
        print("PASS: validation, normalized duplicate scopes, branch distinction, stable edits, persistence and removal")

        let activeDefaults = preferences("aggregation")
        let activityTransport = WatchMonitorTransport()
        var time = epoch
        let activity = BuildWatchMonitor(defaults: activeDefaults, startTicker: false, clock: { time }, perform: activityTransport.perform)
        activityTransport.enqueue("owner/alpha", snapshot([run("alpha", id: 1)]))
        precondition(activity.add("owner/alpha")); await eventually { !activity.isRefreshing }
        activityTransport.enqueue("owner/beta", snapshot([run("beta", id: 2, updatedAt: epoch.addingTimeInterval(1))]))
        precondition(activity.add("owner/beta")); await eventually { !activity.isRefreshing }
        let alpha = activity.repositories[0], beta = activity.repositories[1]
        precondition(activity.activeCount == 2 && activity.compactRepository?.id == beta.id,
                     "The compact active watch follows the most recently updated live workflow")
        var observedCounts: [Int] = []
        let observation = activity.objectWillChange.sink { observedCounts.append(activity.activeCount) }
        time = time.addingTimeInterval(1)
        activityTransport.enqueue("owner/alpha", snapshot([run("alpha", id: 1, status: .completed, conclusion: .success)]))
        alpha.controller.refresh(); await eventually { !activity.isRefreshing && observedCounts.contains(1) }
        precondition(activity.compactRepository?.id == alpha.id,
                     "A newly observed completion takes priority over another watch's active run")
        time = time.addingTimeInterval(1)
        activityTransport.enqueue("owner/beta", snapshot([run("beta", id: 2, status: .completed, conclusion: .failure)]))
        beta.controller.refresh(); await eventually { !activity.isRefreshing && observedCounts.contains(0) }
        precondition(activity.compactRepository?.id == beta.id, "The most recent observed completion wins across watches")
        time = time.addingTimeInterval(12)
        precondition(activity.compactRepository == nil,
                     "Expired completions must be excluded even before a child timer runs")
        activityTransport.enqueue("owner/alpha", snapshot([run("alpha", id: 3)]))
        alpha.controller.refresh(); await eventually { !activity.isRefreshing }
        time = time.addingTimeInterval(76)
        precondition(activity.activeCount == 0 && activity.compactRepository == nil && alpha.controller.isLive,
                     "Aggregate freshness must exclude stale snapshots independently of ticker timing")
        activityTransport.enqueue("owner/beta", snapshot([run("beta", id: 4, updatedAt: time)]))
        beta.controller.refresh(); await eventually { !activity.isRefreshing }
        precondition(activity.activeCount == 1 && activity.compactRepository?.id == beta.id)
        activityTransport.enqueue("owner/beta", .failure(.timedOut))
        beta.controller.refresh(); await eventually { !activity.isRefreshing }
        precondition(activity.activeCount == 0 && activity.compactRepository == nil && beta.controller.runs.first?.id == 4,
                     "A failed watch keeps stale rows without contributing a running indicator")
        observation.cancel()
        print("PASS: live aggregation, settled publisher relay, completion ordering and expiry, stale/failure exclusion")

        let isolatedDefaults = preferences("isolation")
        let delayed = WatchMonitorTransport()
        var isolatedTime = epoch
        let isolated = BuildWatchMonitor(defaults: isolatedDefaults, startTicker: false, clock: { isolatedTime }, perform: delayed.perform)
        let oldGate = DispatchSemaphore(value: 0)
        delayed.enqueue("owner/slow", snapshot([run("slow", id: 10)]), gate: oldGate)
        precondition(isolated.add("owner/slow")); await eventually { delayed.count(for: "owner/slow") == 1 }
        let slowID = isolated.repositories[0].id
        delayed.enqueue("owner/fast", snapshot([run("fast", id: 20)]))
        precondition(isolated.add("owner/fast"))
        let fast = isolated.repositories[1]
        await eventually { fast.controller.isLive }
        precondition(isolated.isRefreshing && isolated.activeCount == 1,
                     "A blocked repository must not delay another repository's first response")
        delayed.enqueue("owner/retargeted", snapshot([run("retargeted", id: 30)]))
        precondition(isolated.update(slowID, input: "owner/retargeted"))
        precondition(!delayed.isCurrent("owner/slow"), "Retargeting must invalidate only that child's request")
        oldGate.signal()
        await eventually { !isolated.isRefreshing }
        precondition(isolated.repository(slowID)?.controller.runs.first?.id == 30 && fast.controller.runs.first?.id == 20,
                     "A late successful response cannot replace the new target or another child's state")
        let removalGate = DispatchSemaphore(value: 0)
        delayed.enqueue("owner/retargeted", snapshot([run("retargeted", id: 31)]), gate: removalGate)
        isolated.repository(slowID)?.controller.refresh()
        await eventually { delayed.count(for: "owner/retargeted") == 2 }
        isolated.remove(slowID)
        precondition(!delayed.isCurrent("owner/retargeted") && !isolated.isRefreshing && isolated.activeCount == 1)
        removalGate.signal()
        try? await Task.sleep(for: .milliseconds(50))
        precondition(isolated.repository(slowID) == nil && fast.controller.isLive && fast.controller.runs.first?.id == 20,
                     "Removing a watch cancels its work and discards late results without affecting other watches")

        delayed.enqueue("owner/failing", .failure(.network))
        precondition(isolated.add("owner/failing")); await eventually { !isolated.isRefreshing }
        let failing = isolated.repositories.last!
        let initialFailures = delayed.count(for: "owner/failing")
        isolatedTime = isolatedTime.addingTimeInterval(30)
        delayed.enqueue("owner/fast", snapshot([run("fast", id: 21)]))
        fast.controller.tick(now: isolatedTime); failing.controller.tick(now: isolatedTime)
        await eventually { !isolated.isRefreshing }
        precondition(delayed.count(for: "owner/failing") == initialFailures && fast.controller.runs.first?.id == 21,
                     "One child's 60-second error backoff must not block another child's 30-second poll")
        isolatedTime = isolatedTime.addingTimeInterval(30)
        delayed.enqueue("owner/failing", snapshot([]))
        failing.controller.tick(now: isolatedTime); await eventually { !isolated.isRefreshing }
        precondition(failing.controller.isLive && delayed.count(for: "owner/failing") == initialFailures + 1)
        print("PASS: concurrent independent watches, retarget/remove cancellation, delayed response isolation and per-watch backoff")

        let tickerDefaults = preferences("ticker")
        let tickerTransport = WatchMonitorTransport()
        let tickerMonitor = BuildWatchMonitor(defaults: tickerDefaults, startTicker: true, clock: { epoch }, perform: tickerTransport.perform)
        tickerTransport.enqueue("owner/initial", snapshot([]))
        precondition(tickerMonitor.add("owner/initial"))
        await eventually { !tickerMonitor.isRefreshing }
        try? await Task.sleep(for: .milliseconds(50))
        precondition(tickerTransport.count == 1, "Starting the ticker must not queue a second immediate connect request")
        tickerMonitor.remove(tickerMonitor.repositories[0].id)
        print("PASS: ticker-enabled additions issue one initial request")
    }
}

private final class WatchMonitorTransport: @unchecked Sendable {
    private struct Key: Hashable {
        let owner: String; let repository: String; let branch: String?; let pullRequest: Int?
        init(_ target: BuildWatchTarget) {
            owner = target.owner.lowercased(); repository = target.repository.lowercased()
            branch = target.branch; pullRequest = target.pullRequest
        }
    }
    private struct Plan { let outcome: BuildWatchOutcome; let gate: DispatchSemaphore? }
    private let lock = NSLock()
    private var plans: [Key: [Plan]] = [:]
    private var requests: [(BuildWatchRequest, BuildWatchCancellation)] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func count(for input: String, branch: String = "") -> Int {
        let key = Key(try! BuildWatchTarget.parse(input, branch: branch))
        lock.lock(); defer { lock.unlock() }
        return requests.filter { Key($0.0.target) == key }.count
    }

    func isCurrent(_ input: String, branch: String = "") -> Bool {
        let key = Key(try! BuildWatchTarget.parse(input, branch: branch))
        lock.lock(); let record = requests.last { Key($0.0.target) == key }; lock.unlock()
        return record.map { $0.1.isCurrent($0.0.generation) } ?? false
    }

    func enqueue(_ input: String, branch: String = "", _ outcome: BuildWatchOutcome, gate: DispatchSemaphore? = nil) {
        let key = Key(try! BuildWatchTarget.parse(input, branch: branch))
        lock.lock(); defer { lock.unlock() }
        plans[key, default: []].append(Plan(outcome: outcome, gate: gate))
    }

    func perform(_ request: BuildWatchRequest, _ cancellation: BuildWatchCancellation) -> BuildWatchOutcome {
        lock.lock()
        requests.append((request, cancellation))
        let key = Key(request.target)
        let plan = plans[key]?.isEmpty == false ? plans[key]!.removeFirst() : Plan(outcome: .failure(.network), gate: nil)
        lock.unlock()
        if let gate = plan.gate { _ = gate.wait(timeout: .now() + 3) }
        // Deliberately return stale successes too, exercising the controller's
        // generation guard even when a transport has already finished its work.
        return plan.outcome
    }
}

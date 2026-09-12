import Foundation
import Darwin

/// Fixture-only coverage. No real gh command, account or repository is contacted.
@main
struct BuildWatchTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func rejects(_ expected: BuildWatchError? = nil, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection") }
        catch { if let expected { expect(error as? BuildWatchError == expected, "Unexpected rejection") } }
    }
    @MainActor static func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Fixture worker did not finish")
    }

    static let sha = String(repeating: "a", count: 40)
    static let otherSHA = String(repeating: "b", count: 40)
    static let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

    static func rawRun(id: Int = 1, status: String = "in_progress", conclusion: String? = nil,
                       attempt: Int = 1, branch: String = "main", sha: String = sha) -> [String: Any] {
        var record: [String: Any] = ["id": id, "name": "CI", "head_branch": branch, "head_sha": sha,
                                    "html_url": "https://github.com/owner/repository/actions/runs/\(id)",
                                    "created_at": "2025-06-15T15:06:40Z", "updated_at": "2025-06-15T15:07:40Z",
                                    "status": status, "run_attempt": attempt]
        record["conclusion"] = conclusion ?? NSNull()
        return record
    }
    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    static func run(id: Int64 = 1, status: BuildWatchRunStatus = .inProgress, conclusion: BuildWatchConclusion? = nil,
                    attempt: Int = 1, headSHA: String = sha) -> BuildWatchRun {
        .init(id: id, name: "CI", headBranch: "main", headSHA: headSHA,
              htmlURL: URL(string: "https://github.com/owner/repository/actions/runs/\(id)")!,
              createdAt: timestamp, updatedAt: timestamp, status: status, conclusion: conclusion, attempt: attempt)
    }
    static func snapshot(_ runs: [BuildWatchRun], scope: String = "main") -> BuildWatchOutcome {
        .success(.init(runs: runs, resolvedBranch: "main", scopeIdentity: scope))
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "api" {
            // This same test binary acts as a fake gh. No shell, network, real
            // credentials, or user GitHub configuration is involved.
            let expectedPrefix = ["api", "--hostname", "github.com", "--method", "GET", "--include",
                                  "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28"]
            guard Array(CommandLine.arguments.dropFirst().prefix(10)) == expectedPrefix,
                  ProcessInfo.processInfo.environment["GH_PROMPT_DISABLED"] == "1",
                  ProcessInfo.processInfo.environment["GH_PAGER"] == "cat",
                  ProcessInfo.processInfo.environment["GIT_TERMINAL_PROMPT"] == "0",
                  FileHandle.standardInput.readDataToEndOfFile().isEmpty else { exit(64) }
            let mode = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
            if mode == "gh-timeout" { try? await Task.sleep(for: .seconds(10)); exit(0) }
            if mode == "gh-oversized" { FileHandle.standardOutput.write(Data(repeating: 65, count: 1_048_600)); exit(0) }
            if mode == "gh-stderr-oversized" { FileHandle.standardError.write(Data(repeating: 65, count: 9_000)); exit(1) }
            if mode == "gh-auth" {
                FileHandle.standardError.write(Data("PRIVATE_FIXTURE_DIAGNOSTIC".utf8))
                FileHandle.standardOutput.write(Data("HTTP/2.0 401\r\n\r\n{}".utf8)); exit(1)
            }
            FileHandle.standardOutput.write(Data("HTTP/2.0 200\r\nContent-Type: application/json\r\n\r\n{\"workflow_runs\":[]}".utf8))
            exit(0)
        }
        let target = try BuildWatchTarget.parse("owner/repository")
        expect(target.branch == nil && target.pullRequest == nil, "Blank branch must select repository default")
        let parsedPR = try BuildWatchTarget.parse("https://github.com/owner/repository/pull/17")
        expect(parsedPR.pullRequest == 17, "PR parsing")
        for invalid in ["https://evil.example/owner/repository", "https://github.com.evil.example/owner/repository", "https://user@github.com/owner/repository", "http://github.com/owner/repository", "owner/repository/extra", "https://github.com/owner/repository/pull/0", "https://github.com/owner/repository?token=private", "https://github.com/owner/%2e%2e", "../repository"] {
            rejects(.invalidTarget) { _ = try BuildWatchTarget.parse(invalid) }
        }
        for branch in ["main?token=secret", "../main", "refs//main", "main\nsecret", "feature.lock", "-f"] {
            rejects(.invalidBranch) { _ = try BuildWatchTarget.parse("owner/repository", branch: branch) }
        }
        expect(BuildWatchTarget.validBranch("feature/a+b&c"), "Safe branch characters must be encoded, not interpreted as arguments")
        for url in ["https://evil.example/owner/repository/actions/runs/1", "https://github.com/owner/other/actions/runs/1", "https://github.com/owner/repository/actions/runs/2", "https://user:secret@github.com/owner/repository/actions/runs/1", "https://github.com/owner/repository/actions/runs/1?next=evil", "file:///tmp/run"] {
            expect(BuildWatchRun.validatedURL(url, target: target, id: 1) == nil, "Run URL must stay on exact GitHub repository/run")
        }
        expect(run(status: .completed, conclusion: nil).state == .unknown, "Missing conclusion must not be successful")
        expect(run(status: .completed, conclusion: .unknown).state == .unknown, "Unknown conclusion must not be successful")
        expect(run(status: .queued, conclusion: .success).state == .queued, "Pending status must outrank old success")
        expect(run(status: .completed, conclusion: .success).state == .success, "Completed success")
        expect(run(status: .completed, conclusion: .cancelled).state == .cancelled, "Cancellation differs from success")
        let parsed = try BuildWatchTransport.decodeRuns(data(["workflow_runs": [rawRun(status: "new_future_state")]]), target: target, expectedBranch: "main", expectedSHA: nil)
        expect(parsed.first?.state == .unknown, "Unknown GitHub status must remain unknown")
        rejects { _ = try BuildWatchTransport.decodeRuns(data(["workflow_runs": [rawRun(branch: "other")]]), target: target, expectedBranch: "main", expectedSHA: nil) }
        rejects { _ = try BuildWatchTransport.decodeRuns(data(["workflow_runs": [rawRun(sha: otherSHA)]]), target: target, expectedBranch: nil, expectedSHA: sha) }
        print("PASS: target/branch/run URL validation and conservative status/conclusion decoding")

        let request = BuildWatchRequest(target: target, generation: 0)
        let cancellation = BuildWatchCancellation()
        var paths: [String] = []
        let defaultOutcome = BuildWatchTransport.fetch(request, cancellation) { path, _, _ in
            paths.append(path)
            if path == "repos/owner/repository" { return try data(["full_name": "owner/repository", "default_branch": "trunk"]) }
            return try data(["workflow_runs": [rawRun(branch: "trunk")]])
        }
        guard case .success(let defaultSnapshot) = defaultOutcome else { fatalError("Default branch fixture failed") }
        expect(defaultSnapshot.resolvedBranch == "trunk" && paths.last?.contains("branch=trunk") == true, "Default branch must be resolved from metadata")
        let plusTarget = try BuildWatchTarget.parse("owner/repository", branch: "feature/c++")
        var plusEndpoint = ""
        _ = BuildWatchTransport.fetch(.init(target: plusTarget, generation: 0), cancellation) { path, _, _ in
            plusEndpoint = path
            return try data(["workflow_runs": [rawRun(branch: "feature/c++")]])
        }
        expect(plusEndpoint.contains("branch=feature/c%2B%2B"), "Literal plus signs in branches must survive form-style query decoding")
        let prTarget = try BuildWatchTarget.parse("https://github.com/owner/repository/pull/17")
        paths = []
        let prOutcome = BuildWatchTransport.fetch(.init(target: prTarget, generation: 0), cancellation) { path, _, _ in
            paths.append(path)
            if path.contains("/pulls/") {
                return try data(["number": 17, "head": ["sha": sha, "ref": "same-name-in-a-fork"], "base": ["repo": ["full_name": "owner/repository"]]])
            }
            return try data(["workflow_runs": [rawRun(branch: "same-name-in-a-fork")]])
        }
        guard case .success(let prSnapshot) = prOutcome else { fatalError("PR fixture failed") }
        expect(prSnapshot.scopeIdentity == sha && paths.last?.contains("head_sha=\(sha)") == true && paths.last?.contains("branch=") == false,
               "Fork PR watches must use exact head SHA in the base repository")
        let movedPR = BuildWatchTransport.fetch(.init(target: prTarget, generation: 0), cancellation) { _, _, _ in
            try data(["number": 17, "head": ["sha": sha, "ref": "main"], "base": ["repo": ["full_name": "other/repository"]]])
        }
        guard case .failure(.invalidResponse) = movedPR else { fatalError("Wrong base repo must fail") }
        for (code, error) in [(401, BuildWatchError.authentication), (403, .forbidden), (404, .notFound), (429, .forbidden)] {
            rejects(error) { _ = try BuildWatchTransport.responseBody(Data("HTTP/2.0 \(code)\r\nContent-Type: application/json\r\n\r\n{}".utf8), stderr: Data(), exitCode: 1) }
        }
        rejects(.authentication) { _ = try BuildWatchTransport.responseBody(Data(), stderr: Data("SECRET: run gh auth login".utf8), exitCode: 1) }
        print("PASS: repository default branch, PR head SHA/base binding, and safe HTTP/auth error classification")

        let processDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("broschy-build-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: processDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: processDirectory) }
        for name in ["gh-ok", "gh-timeout", "gh-oversized", "gh-stderr-oversized", "gh-auth"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: processDirectory.appendingPathComponent(name))
        }
        let endpoint = "repos/owner/repository/actions/runs?branch=main&per_page=10"
        let processResult = try BuildWatchTransport.runAPI(endpoint, executable: processDirectory.appendingPathComponent("gh-ok"), request: request, cancellation: cancellation)
        expect(String(decoding: processResult, as: UTF8.self) == "{\"workflow_runs\":[]}", "Real argv transport must enforce GET, GitHub host, disabled prompts, no stdin and strip headers")
        let beganTimeout = Date()
        rejects(.timedOut) { _ = try BuildWatchTransport.runAPI(endpoint, executable: processDirectory.appendingPathComponent("gh-timeout"), request: request, cancellation: cancellation, timeout: 0.15) }
        expect(Date().timeIntervalSince(beganTimeout) < 2, "Subprocess timeout must terminate a stalled command")
        rejects(.oversized) { _ = try BuildWatchTransport.runAPI(endpoint, executable: processDirectory.appendingPathComponent("gh-oversized"), request: request, cancellation: cancellation) }
        rejects(.oversized) { _ = try BuildWatchTransport.runAPI(endpoint, executable: processDirectory.appendingPathComponent("gh-stderr-oversized"), request: request, cancellation: cancellation) }
        rejects(.authentication) { _ = try BuildWatchTransport.runAPI(endpoint, executable: processDirectory.appendingPathComponent("gh-auth"), request: request, cancellation: cancellation) }
        expect(!BuildWatchError.authentication.message.contains("PRIVATE_FIXTURE_DIAGNOSTIC"), "Raw CLI diagnostics must not reach the UI")
        let processCancellation = BuildWatchCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { processCancellation.invalidate() }
        let beganCancellation = Date()
        rejects(.cancelled) { _ = try BuildWatchTransport.runAPI(endpoint, executable: processDirectory.appendingPathComponent("gh-timeout"), request: request, cancellation: processCancellation) }
        expect(Date().timeIntervalSince(beganCancellation) < 2, "Retarget/stop must cancel a live subprocess")
        print("PASS: real Process argv/GET/host/stdin settings, timeout, cancellation, bounded output, private diagnostic suppression")

        let suite = "app.broschy.build-watch-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = FixtureTransport()
        var time = timestamp
        let controller = BuildWatchController(defaults: defaults, startTicker: false, clock: { time }, perform: fixture.perform)
        controller.tick(now: time)
        expect(fixture.count == 0 && !controller.isEnabled, "No network before explicit opt-in")
        fixture.enqueue(snapshot([run(status: .completed, conclusion: .success)]))
        expect(controller.connect("owner/repository"), "Valid connection")
        await eventually { !controller.isRefreshing }
        expect(controller.recentCompletion == nil && controller.isLive && controller.activeCount == 0, "First load must not celebrate historical runs")
        fixture.enqueue(snapshot([run(id: 2)]))
        time = time.addingTimeInterval(29); controller.tick(now: time)
        expect(fixture.count == 1, "Polling must not run before 30 seconds")
        time = time.addingTimeInterval(1); controller.tick(now: time)
        await eventually { !controller.isRefreshing }
        expect(controller.activeCount == 1, "Active workflow count")
        fixture.enqueue(snapshot([run(id: 2, status: .completed, conclusion: .success)]))
        controller.refresh(); await eventually { !controller.isRefreshing }
        expect(controller.recentCompletion?.run.id == 2, "Observed active-to-completed transition must produce a completion")
        time = time.addingTimeInterval(12); controller.tick(now: time)
        expect(controller.recentCompletion == nil, "Completion capsule expires after 12 seconds")
        fixture.enqueue(snapshot([run(id: 2, status: .completed, conclusion: .success)]))
        controller.refresh(); await eventually { !controller.isRefreshing }
        expect(controller.recentCompletion == nil, "Repeated completion must not alert twice")
        fixture.enqueue(snapshot([run(id: 2, attempt: 2)]))
        controller.refresh(); await eventually { !controller.isRefreshing }
        fixture.enqueue(snapshot([run(id: 2, status: .completed, conclusion: .failure, attempt: 2)]))
        controller.refresh(); await eventually { !controller.isRefreshing }
        expect(controller.recentCompletion?.run.attempt == 2 && controller.recentCompletion?.run.state == .failure, "Rerun attempts must be separately observed and reported")

        fixture.enqueue(snapshot([run(id: 3)])); controller.refresh(); await eventually { !controller.isRefreshing }
        fixture.enqueue(.failure(.timedOut)); controller.refresh(); await eventually { !controller.isRefreshing }
        expect(!controller.isLive && controller.activeCount == 0 && controller.runs.first?.id == 3 && controller.errorMessage == BuildWatchError.timedOut.message,
               "Failed polls retain a labeled stale snapshot but must clear live/running indicators")
        let failedCount = fixture.count
        time = time.addingTimeInterval(59); controller.tick(now: time)
        expect(fixture.count == failedCount, "First error backs off 60 seconds")
        fixture.enqueue(.failure(.network)); time = time.addingTimeInterval(1); controller.tick(now: time)
        await eventually { !controller.isRefreshing }
        let secondFailedCount = fixture.count
        time = time.addingTimeInterval(119); controller.tick(now: time)
        expect(fixture.count == secondFailedCount, "Second error backs off 120 seconds")
        fixture.enqueue(.failure(.network)); time = time.addingTimeInterval(1); controller.tick(now: time)
        await eventually { !controller.isRefreshing }
        let thirdFailedCount = fixture.count
        time = time.addingTimeInterval(299); controller.tick(now: time)
        expect(fixture.count == thirdFailedCount, "Later errors back off 300 seconds")
        print("PASS: opt-in, 30-second polling, baseline, transition/rerun dedup, completion expiry, stale failure state, bounded backoff")

        let restarted = BuildWatchController(defaults: defaults, startTicker: false, clock: { time }, perform: fixture.perform)
        fixture.enqueue(snapshot([run(id: 2, attempt: 2)])); restarted.refresh(); await eventually { !restarted.isRefreshing }
        fixture.enqueue(snapshot([run(id: 2, status: .completed, conclusion: .failure, attempt: 2)])); restarted.refresh(); await eventually { !restarted.isRefreshing }
        expect(restarted.recentCompletion == nil, "Persisted completion IDs prevent replay after restart")
        fixture.enqueue(snapshot([run(id: 5)], scope: sha)); expect(restarted.connect("https://github.com/owner/repository/pull/17"), "PR connect")
        await eventually { !restarted.isRefreshing }
        fixture.enqueue(snapshot([run(id: 5, status: .completed, conclusion: .success, headSHA: otherSHA)], scope: otherSHA))
        restarted.refresh(); await eventually { !restarted.isRefreshing }
        expect(restarted.recentCompletion == nil, "New PR head establishes a baseline instead of celebrating an old head")

        let blocked = FixtureTransport()
        blocked.blockNext = true
        blocked.enqueue(snapshot([run(id: 99)]))
        let retargeted = BuildWatchController(defaults: UserDefaults(suiteName: suite + ".retarget")!, startTicker: false, perform: blocked.perform)
        defer { UserDefaults(suiteName: suite + ".retarget")?.removePersistentDomain(forName: suite + ".retarget") }
        expect(retargeted.connect("owner/repository"), "Start blocked request")
        await eventually { blocked.count == 1 }
        blocked.enqueue(snapshot([run(id: 100)]))
        expect(retargeted.connect("owner/new-repository"), "Retarget pending request")
        blocked.release.signal()
        await eventually { !retargeted.isRefreshing && blocked.count == 2 }
        expect(retargeted.target?.repository == "new-repository" && retargeted.runs.first?.id == 100,
               "Old responses must not overwrite retargeted state")
        blocked.blockNext = true; blocked.enqueue(snapshot([run(id: 101)])); retargeted.refresh()
        await eventually { blocked.count == 3 }
        retargeted.disconnect(); blocked.release.signal()
        await eventually { !retargeted.isRefreshing }
        try? await Task.sleep(for: .milliseconds(50))
        expect(!retargeted.isEnabled && retargeted.runs.isEmpty && !retargeted.isLive && retargeted.status == .disconnected,
               "Disconnect invalidates a late successful response")
        let preferences = defaults.dictionaryRepresentation()
        expect(preferences["buildWatchTarget"] is Data && preferences["buildWatchSeenCompletions"] is [String], "Minimal configuration/dedup persistence")
        expect(!preferences.keys.contains { $0.lowercased().contains("token") }, "No credentials are stored")
        print("PASS: restart dedup, PR head changes, retarget/disconnect stale-response cancellation, minimal preferences")
    }
}

final class FixtureTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [BuildWatchOutcome] = []
    private var requests = 0
    private var block = false
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var blockNext: Bool {
        get { lock.lock(); defer { lock.unlock() }; return block }
        set { lock.lock(); block = newValue; lock.unlock() }
    }
    func enqueue(_ outcome: BuildWatchOutcome) { lock.lock(); outcomes.append(outcome); lock.unlock() }
    func perform(_ request: BuildWatchRequest, _ cancellation: BuildWatchCancellation) -> BuildWatchOutcome {
        lock.lock()
        requests += 1
        let outcome = outcomes.isEmpty ? BuildWatchOutcome.failure(.network) : outcomes.removeFirst()
        let shouldBlock = block; block = false
        lock.unlock()
        if shouldBlock { _ = release.wait(timeout: .now() + 5) }
        return outcome
    }
}

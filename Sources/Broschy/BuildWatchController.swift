import Combine
import Darwin
import Foundation

@MainActor
final class BuildWatchController: ObservableObject {
    @Published private(set) var target: BuildWatchTarget?
    @Published private(set) var isEnabled = false
    @Published private(set) var status: BuildWatchConnectionStatus = .disconnected
    @Published private(set) var runs: [BuildWatchRun] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLive = false
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var inputError: String?
    @Published private(set) var resolvedBranch: String?
    @Published private(set) var recentCompletion: BuildWatchCompletion?

    private let defaults: UserDefaults
    private let storageNamespace: String?
    private let perform: (BuildWatchRequest, BuildWatchCancellation) -> BuildWatchOutcome
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "app.broschy.build-watch", qos: .utility)
    private let cancellation = BuildWatchCancellation()
    private var ticker: Timer?
    private var generation = 0
    private var inFlight = false
    private var pendingRefresh = false
    private var nextRefresh = Date.distantPast
    private var failureCount = 0
    private var baselineScope: String?
    private var observedActive = Set<String>()
    private var seenCompletions: [String]

    init(defaults: UserDefaults = .standard, storageNamespace: String? = nil,
         startTicker: Bool = true, clock: @escaping () -> Date = Date.init,
         perform: @escaping (BuildWatchRequest, BuildWatchCancellation) -> BuildWatchOutcome = BuildWatchTransport.fetch) {
        self.defaults = defaults
        self.storageNamespace = storageNamespace
        self.clock = clock
        self.perform = perform
        if let data = defaults.data(forKey: Self.storageKey("buildWatchTarget", namespace: storageNamespace)), data.count <= 2_048,
           let stored = try? JSONDecoder().decode(BuildWatchTarget.self, from: data), stored.isValid {
            target = stored
            isEnabled = defaults.bool(forKey: Self.storageKey("buildWatchEnabled", namespace: storageNamespace))
        }
        seenCompletions = (defaults.stringArray(forKey: Self.storageKey("buildWatchSeenCompletions", namespace: storageNamespace)) ?? [])
            .filter { $0.range(of: "^[a-f0-9]{64}:[0-9]+:[0-9]+$", options: .regularExpression) != nil }.suffix(30).map { $0 }
        if startTicker { startMonitoring() }
    }

    deinit { ticker?.invalidate(); cancellation.invalidate() }

    var activeCount: Int { isLive ? runs.filter(\.isActive).count : 0 }
    var hasCompactActivity: Bool { activeCount > 0 || recentCompletion != nil }

    func startMonitoring() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        if isEnabled { refresh() }
    }

    static func storageKey(_ key: String, namespace: String?) -> String {
        namespace.map { $0 + "." + key } ?? key
    }

    /// Copy only validated configuration and bounded completion keys. The nil
    /// namespace keeps existing single-watch callers and their preferences intact.
    func copySavedConfiguration(to namespace: String) {
        if let target {
            defaults.set(try? JSONEncoder().encode(target), forKey: Self.storageKey("buildWatchTarget", namespace: namespace))
        }
        defaults.set(isEnabled, forKey: Self.storageKey("buildWatchEnabled", namespace: namespace))
        defaults.set(seenCompletions, forKey: Self.storageKey("buildWatchSeenCompletions", namespace: namespace))
    }

    func removeSavedConfiguration() {
        for key in ["buildWatchTarget", "buildWatchEnabled", "buildWatchSeenCompletions"] {
            defaults.removeObject(forKey: Self.storageKey(key, namespace: storageNamespace))
        }
    }

    @discardableResult
    func connect(_ input: String, branch: String = "") -> Bool {
        let parsed: BuildWatchTarget
        do { parsed = try BuildWatchTarget.parse(input, branch: branch) }
        catch { inputError = (error as? BuildWatchError ?? .invalidTarget).message; return false }
        generation += 1
        cancellation.setGeneration(generation)
        target = parsed
        isEnabled = true
        status = .connecting
        inputError = nil
        errorMessage = nil
        runs = []; isLive = false; lastUpdatedAt = nil; resolvedBranch = nil; recentCompletion = nil
        baselineScope = nil; observedActive = []; failureCount = 0
        defaults.set(try? JSONEncoder().encode(parsed), forKey: Self.storageKey("buildWatchTarget", namespace: storageNamespace))
        defaults.set(true, forKey: Self.storageKey("buildWatchEnabled", namespace: storageNamespace))
        refresh()
        return true
    }

    func disconnect() {
        generation += 1; cancellation.setGeneration(generation)
        isEnabled = false; status = .disconnected; isRefreshing = false; isLive = false
        runs = []; recentCompletion = nil; lastUpdatedAt = nil; resolvedBranch = nil
        errorMessage = nil; inputError = nil; pendingRefresh = false
        baselineScope = nil; observedActive = []
        defaults.set(false, forKey: Self.storageKey("buildWatchEnabled", namespace: storageNamespace))
    }

    func tick(now: Date? = nil) {
        let now = now ?? clock()
        if let completion = recentCompletion, now.timeIntervalSince(completion.observedAt) >= 12 { recentCompletion = nil }
        // A sleeping Mac must not show an old running badge while a fresh poll
        // is outstanding after wake.
        if let lastUpdatedAt, now.timeIntervalSince(lastUpdatedAt) > 75 { isLive = false }
        if isEnabled && !inFlight && now >= nextRefresh { refresh() }
    }

    func refresh() {
        guard isEnabled, let target else { return }
        if inFlight { pendingRefresh = true; return }
        let request = BuildWatchRequest(target: target, generation: generation)
        inFlight = true; isRefreshing = true
        if lastUpdatedAt == nil { status = .connecting }
        let worker = perform, cancellation = cancellation
        queue.async { [weak self] in
            let outcome = worker(request, cancellation)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if self.isEnabled && self.generation == request.generation {
                    self.isRefreshing = false
                    self.accept(outcome, target: request.target, now: self.clock())
                }
                let pending = self.pendingRefresh
                self.pendingRefresh = false
                if pending && self.isEnabled { self.refresh() }
            }
        }
    }

    private func accept(_ outcome: BuildWatchOutcome, target: BuildWatchTarget, now: Date) {
        switch outcome {
        case .failure(let error):
            status = .failure; errorMessage = error.message; isLive = false; recentCompletion = nil
            failureCount += 1
            nextRefresh = now.addingTimeInterval([60.0, 120.0, 300.0][min(2, failureCount - 1)])
        case .success(let snapshot):
            let newScope = target.identity + ":" + snapshot.scopeIdentity
            if baselineScope == newScope {
                let completed = snapshot.runs.filter { run in
                    run.isCompleted && observedActive.contains(run.completionKey)
                        && !seenCompletions.contains(target.identity + ":" + run.completionKey)
                }.sorted { $0.updatedAt > $1.updatedAt }
                if let run = completed.first { recentCompletion = .init(run: run, observedAt: now) }
                for run in completed { seenCompletions.append(target.identity + ":" + run.completionKey) }
                seenCompletions = Array(seenCompletions.suffix(30))
                defaults.set(seenCompletions, forKey: Self.storageKey("buildWatchSeenCompletions", namespace: storageNamespace))
            } else {
                baselineScope = newScope
                recentCompletion = nil
            }
            observedActive = Set(snapshot.runs.filter(\.isActive).map(\.completionKey))
            runs = Array(snapshot.runs.prefix(10)); resolvedBranch = snapshot.resolvedBranch
            lastUpdatedAt = now; status = .connected; errorMessage = nil; isLive = true
            failureCount = 0; nextRefresh = now.addingTimeInterval(30)
        }
    }
}

final class BuildWatchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var invalidated = false
    func setGeneration(_ value: Int) { lock.lock(); generation = value; lock.unlock() }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    func isCurrent(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return !invalidated && generation == value }
}

enum BuildWatchTransport {
    typealias API = (String, BuildWatchRequest, BuildWatchCancellation) throws -> Data

    static func fetch(_ request: BuildWatchRequest, _ cancellation: BuildWatchCancellation) -> BuildWatchOutcome {
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        return fetch(request, cancellation) { endpoint, request, cancellation in
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw BuildWatchError.timedOut }
            return try api(endpoint, request: request, cancellation: cancellation,
                           timeout: TimeInterval(deadline - now) / 1_000_000_000)
        }
    }

    static func fetch(_ request: BuildWatchRequest, _ cancellation: BuildWatchCancellation, api: API) -> BuildWatchOutcome {
        do {
            guard request.target.isValid else { throw BuildWatchError.invalidTarget }
            guard cancellation.isCurrent(request.generation) else { throw BuildWatchError.cancelled }
            let target = request.target
            let base = "repos/\(target.owner)/\(target.repository)"
            let branch: String, scope: String, filter: URLQueryItem
            if let number = target.pullRequest {
                let data = try api(base + "/pulls/\(number)", request, cancellation)
                let pr = try JSONDecoder().decode(PullRequestResponse.self, from: data)
                guard pr.number == number, BuildWatchTarget.validSHA(pr.head.sha), BuildWatchTarget.validBranch(pr.head.ref),
                      pr.base.repo.full_name.lowercased() == "\(target.owner)/\(target.repository)".lowercased() else { throw BuildWatchError.invalidResponse }
                branch = pr.head.ref; scope = pr.head.sha.lowercased(); filter = URLQueryItem(name: "head_sha", value: pr.head.sha)
            } else {
                if let selected = target.branch { branch = selected }
                else {
                    let data = try api(base, request, cancellation)
                    let repository = try JSONDecoder().decode(RepositoryResponse.self, from: data)
                    guard repository.full_name.lowercased() == "\(target.owner)/\(target.repository)".lowercased(),
                          BuildWatchTarget.validBranch(repository.default_branch) else { throw BuildWatchError.invalidResponse }
                    branch = repository.default_branch
                }
                scope = branch; filter = URLQueryItem(name: "branch", value: branch)
            }
            guard cancellation.isCurrent(request.generation) else { throw BuildWatchError.cancelled }
            var query = URLComponents()
            query.queryItems = [filter, URLQueryItem(name: "per_page", value: "10")]
            // Form-style query decoders treat a literal '+' as a space.
            let encodedQuery = (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            let data = try api(base + "/actions/runs?" + encodedQuery, request, cancellation)
            let runs = try decodeRuns(data, target: target, expectedBranch: target.pullRequest == nil ? branch : nil,
                                      expectedSHA: target.pullRequest == nil ? nil : scope)
            guard cancellation.isCurrent(request.generation) else { throw BuildWatchError.cancelled }
            return .success(.init(runs: runs, resolvedBranch: branch, scopeIdentity: scope))
        } catch { return .failure(error as? BuildWatchError ?? .invalidResponse) }
    }

    static func decodeRuns(_ data: Data, target: BuildWatchTarget, expectedBranch: String?, expectedSHA: String?) throws -> [BuildWatchRun] {
        guard data.count <= 1_048_576 else { throw BuildWatchError.oversized }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(RunsResponse.self, from: data)
        guard response.workflow_runs.count <= 100 else { throw BuildWatchError.invalidResponse }
        var ids = Set<Int64>()
        return try response.workflow_runs.prefix(10).map { raw in
            guard raw.id > 0, ids.insert(raw.id).inserted, raw.run_attempt > 0, raw.run_attempt <= 10_000,
                  BuildWatchTarget.validSHA(raw.head_sha), BuildWatchTarget.validBranch(raw.head_branch),
                  expectedBranch == nil || raw.head_branch == expectedBranch,
                  expectedSHA == nil || raw.head_sha.lowercased() == expectedSHA?.lowercased(),
                  let url = BuildWatchRun.validatedURL(raw.html_url, target: target, id: raw.id),
                  raw.updated_at >= raw.created_at else { throw BuildWatchError.invalidResponse }
            let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Workflow"
            guard name.utf8.count <= 512, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BuildWatchError.invalidResponse }
            return BuildWatchRun(id: raw.id, name: name.isEmpty ? "Workflow" : String(name.prefix(100)), headBranch: raw.head_branch,
                                 headSHA: raw.head_sha, htmlURL: url, createdAt: raw.created_at, updatedAt: raw.updated_at,
                                 status: BuildWatchRunStatus(rawValue: raw.status) ?? .unknown,
                                 conclusion: raw.conclusion.map { BuildWatchConclusion(rawValue: $0) ?? .unknown }, attempt: raw.run_attempt)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private struct RepositoryResponse: Decodable { let full_name: String; let default_branch: String }
    private struct PullRequestResponse: Decodable {
        let number: Int; let head: Head; let base: Base
        struct Head: Decodable { let sha: String; let ref: String }
        struct Base: Decodable { let repo: Repo }
        struct Repo: Decodable { let full_name: String }
    }
    private struct RunsResponse: Decodable { let workflow_runs: [RunResponse] }
    private struct RunResponse: Decodable {
        let id: Int64; let name: String?; let head_branch: String; let head_sha: String; let html_url: String
        let created_at: Date; let updated_at: Date; let status: String; let conclusion: String?; let run_attempt: Int
    }

    static func executableURL() -> URL? {
        var paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            paths.append(String(directory) + "/gh")
        }
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            return url
        }
        return nil
    }

    private static func api(_ endpoint: String, request: BuildWatchRequest, cancellation: BuildWatchCancellation,
                            timeout: TimeInterval) throws -> Data {
        guard let executable = executableURL() else { throw BuildWatchError.missingCLI }
        return try runAPI(endpoint, executable: executable, request: request, cancellation: cancellation, timeout: timeout)
    }

    static func runAPI(_ endpoint: String, executable: URL, request: BuildWatchRequest,
                       cancellation: BuildWatchCancellation, timeout: TimeInterval = 15) throws -> Data {
        guard cancellation.isCurrent(request.generation) else { throw BuildWatchError.cancelled }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["api", "--hostname", "github.com", "--method", "GET", "--include",
                             "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", endpoint]
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_PAGER"] = "cat"; environment["PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw BuildWatchError.missingCLI }
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var output = Data(), errors = Data(), open = [true, true]
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.05, min(15, timeout)) * 1_000_000_000)
        var failure: BuildWatchError?
        while open.contains(true) || process.isRunning {
            if !cancellation.isCurrent(request.generation) { failure = .cancelled; break }
            if DispatchTime.now().uptimeNanoseconds >= deadline { failure = .timedOut; break }
            var polls = descriptors.enumerated().map { pollfd(fd: open[$0.offset] ? $0.element : -1, events: Int16(POLLIN | POLLHUP), revents: 0) }
            _ = poll(&polls, UInt32(polls.count), 50)
            for index in 0..<2 where open[index] && polls[index].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 8_192)
                let count = read(descriptors[index], &buffer, buffer.count)
                if count == 0 { open[index] = false }
                else if count > 0 {
                    if index == 0 { output.append(contentsOf: buffer.prefix(count)) }
                    else { errors.append(contentsOf: buffer.prefix(count)) }
                    if output.count > 1_048_576 || errors.count > 8_192 { failure = .oversized; break }
                } else if errno != EAGAIN && errno != EINTR { failure = .network; break }
            }
            if failure != nil { break }
        }
        if failure != nil && process.isRunning {
            process.terminate()
            let killAt = DispatchTime.now().uptimeNanoseconds + 200_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < killAt { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        if let failure { throw failure }
        return try responseBody(output, stderr: errors, exitCode: process.terminationStatus)
    }

    static func responseBody(_ data: Data, stderr: Data, exitCode: Int32) throws -> Data {
        guard data.count <= 1_048_576, stderr.count <= 8_192 else { throw BuildWatchError.oversized }
        let crlf = Data("\r\n\r\n".utf8), lf = Data("\n\n".utf8)
        let split = data.range(of: crlf) ?? data.range(of: lf)
        let header = split.map { String(decoding: data[..<$0.lowerBound], as: UTF8.self) } ?? ""
        let firstLine = header.components(separatedBy: .newlines).first ?? ""
        let code = firstLine.hasPrefix("HTTP/") ? firstLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } : nil
        switch code {
        case 401: throw BuildWatchError.authentication
        case 403, 429: throw BuildWatchError.forbidden
        case 404: throw BuildWatchError.notFound
        case 200:
            guard exitCode == 0, let split else { throw BuildWatchError.network }
            return data.subdata(in: split.upperBound..<data.count)
        default:
            // Classify bounded CLI diagnostics, but never surface/log their text.
            let diagnostic = String(decoding: stderr, as: UTF8.self).lowercased()
            if diagnostic.contains("gh auth login") || diagnostic.contains("http 401") { throw BuildWatchError.authentication }
            if diagnostic.contains("http 403") || diagnostic.contains("http 429") { throw BuildWatchError.forbidden }
            if diagnostic.contains("http 404") { throw BuildWatchError.notFound }
            throw BuildWatchError.network
        }
    }
}

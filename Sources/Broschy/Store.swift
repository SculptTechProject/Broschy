import Combine
import Foundation

@MainActor
final class FlowStore: ObservableObject {
    @Published var taskTitle: String = "" {
        didSet {
            if taskTitle.count > 160 { taskTitle = String(taskTitle.prefix(160)) }
            scheduleSave()
        }
    }
    @Published var note: String = "" {
        didSet {
            if note.count > 4_000 { note = String(note.prefix(4_000)) }
            scheduleSave()
        }
    }
    @Published private(set) var timerState = FlowTimerState()
    @Published private(set) var jobs: [FlowJob] = []
    @Published private(set) var storageError: String?

    private struct SavedState: Codable {
        var taskTitle: String
        var note: String
        var timerState: FlowTimerState
    }

    private let supportURL: URL
    private let jobsURL: URL
    private var ticker: Timer?
    private var saveWork: DispatchWorkItem?
    private var isLoading = true
    private var needsStateBackup = false
    private var recoveryNotice: String?

    init(supportDirectory: URL? = nil, startTicker: Bool = true) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Keep the legacy directory to preserve notes, timers, and Signals across the Broschy rename.
        supportURL = supportDirectory ?? applicationSupport.appendingPathComponent("NotchFlow", isDirectory: true)
        jobsURL = supportURL.appendingPathComponent("jobs", isDirectory: true)
        do {
            try ensureDirectories()
            try loadState()
        } catch {
            needsStateBackup = FileManager.default.fileExists(atPath: supportURL.appendingPathComponent("state.json").path)
            storageError = "Could not read Broschy data. Error: \((error as NSError).domain) (\((error as NSError).code))."
        }
        isLoading = false
        tick()
        if startTicker {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    func start(minutes: Int) {
        timerState.start(minutes: minutes)
        saveNow()
    }

    func togglePause() {
        timerState.togglePause()
        saveNow()
    }

    func resetTimer() {
        timerState.reset()
        saveNow()
    }

    func dismissCompletion() {
        timerState.dismissCompletion()
        saveNow()
    }

    func tick(now: Date = Date()) {
        let wasRunning = timerState.isRunning
        timerState.tick(now: now)
        if wasRunning && !timerState.isRunning { saveNow() }
        refreshJobs()
    }

    /// The app delegate calls this on termination to flush an in-progress edit.
    func saveNow() {
        guard !isLoading else { return }
        saveWork?.cancel()
        saveWork = nil
        do {
            try ensureDirectories()
            let stateURL = supportURL.appendingPathComponent("state.json")
            if needsStateBackup {
                let backupURL = supportURL.appendingPathComponent("state-recovery-" + UUID().uuidString + ".json")
                try FileManager.default.moveItem(at: stateURL, to: backupURL)
                needsStateBackup = false
                recoveryNotice = "The previous data could not be read. A backup was saved as \(backupURL.lastPathComponent)."
            }
            let state = SavedState(taskTitle: taskTitle, note: note, timerState: timerState)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
            storageError = recoveryNotice
        } catch {
            storageError = "Could not save Broschy data. Error: \((error as NSError).domain) (\((error as NSError).code))."
        }
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func ensureDirectories() throws {
        for directory in [supportURL, jobsURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
    }

    private func safeData(at url: URL, maximumSize: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try Data(contentsOf: url)
    }

    private func loadState() throws {
        let stateURL = supportURL.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SavedState.self, from: safeData(at: stateURL, maximumSize: 64_000))
        guard state.timerState.isValid else { throw CocoaError(.fileReadCorruptFile) }
        taskTitle = String(state.taskTitle.prefix(160))
        note = String(state.note.prefix(4_000))
        timerState = state.timerState
    }

    private func refreshJobs() {
        do {
            let directoryValues = try jobsURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let urls = try FileManager.default.contentsOfDirectory(at: jobsURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                .sorted {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs > rhs
                }
                .prefix(48)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded: [FlowJob] = urls.compactMap { url in
                guard let data = try? safeData(at: url, maximumSize: 32_000),
                      let job = try? decoder.decode(FlowJob.self, from: data),
                      UUID(uuidString: job.id) != nil,
                      job.id == url.deletingPathExtension().lastPathComponent,
                      job.title.count <= 160, job.workingDirectory.count <= 4_096,
                      (job.status == .running ? job.finishedAt == nil : job.finishedAt != nil) else { return nil }
                return job
            }
            let newest = Array(decoded.sorted { $0.startedAt > $1.startedAt }.prefix(12))
            if jobs != newest { jobs = newest }
        } catch {
            storageError = "Could not read command history. Error: \((error as NSError).domain) (\((error as NSError).code))."
        }
    }
}

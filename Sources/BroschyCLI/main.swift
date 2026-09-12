import Darwin
import Dispatch
import Foundation

struct JobRecord: Codable {
    let id: String
    let title: String
    var status: String
    let startedAt: Date
    var finishedAt: Date?
    var exitCode: Int?
    let workingDirectory: String
}

func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data(("broschy: " + message + "\n").utf8))
}

func usage() {
    print("""
    Broschy — show command status beside the MacBook notch.

    Usage:
      broschy-cli run [--label \"Tests\"] -- <executable> [arguments...]
      broschy-cli notify --title \"Done\" --status succeeded|failed

    Examples:
      broschy-cli run --label \"Swift tests\" -- /usr/bin/swift test
      broschy-cli run --label \"Build\" -- npm run build

    Arguments execute directly, without shell expansion. For a pipeline, pass
    an explicit shell yourself. Command arguments and output are not saved.
    """)
}

func jobsDirectory() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    // This legacy directory is shared with the app and preserves existing Signals history.
    let support = base.appendingPathComponent("NotchFlow", isDirectory: true)
    let jobs = support.appendingPathComponent("jobs", isDirectory: true)
    for directory in [support, jobs] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
    return jobs
}

func writeJob(_ job: JobRecord, to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(job).write(to: directory.appendingPathComponent(job.id + ".json"), options: .atomic)
}

func executableURL(_ executable: String) -> URL? {
    if executable.contains("/") {
        let url = URL(fileURLWithPath: executable, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    for component in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(separatedBy: ":") {
        let path = component.isEmpty ? FileManager.default.currentDirectoryPath : component
        let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(executable)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func record(_ number: Int32) { lock.lock(); value = number; lock.unlock() }
    var signalNumber: Int32? { lock.lock(); defer { lock.unlock() }; return value }
}

func runCommand(_ input: [String], directoryOverride: URL? = nil) -> Int32 {
    var label: String?
    var index = 0
    while index < input.count && input[index] != "--" {
        guard input[index] == "--label", index + 1 < input.count, label == nil else {
            diagnostic("Expected [--label \"Name\"] -- <executable> [arguments...].")
            return 64
        }
        label = input[index + 1]
        index += 2
    }
    guard index < input.count, input[index] == "--", index + 1 < input.count else {
        diagnostic("A command is required after --.")
        return 64
    }
    let command = Array(input.dropFirst(index + 1))
    let title = label ?? URL(fileURLWithPath: command[0]).lastPathComponent
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 160 else {
        diagnostic("Label must contain 1–160 characters.")
        return 64
    }
    let directory: URL
    var job = JobRecord(id: UUID().uuidString, title: title, status: "running", startedAt: Date(), workingDirectory: FileManager.default.currentDirectoryPath)
    do {
        directory = try directoryOverride ?? jobsDirectory()
        try writeJob(job, to: directory)
    } catch {
        diagnostic("Cannot save job: \(error.localizedDescription)")
        return 74
    }

    func finish(status: String, code: Int32) -> Int32 {
        job.status = status
        job.finishedAt = Date()
        job.exitCode = Int(code)
        do { try writeJob(job, to: directory) }
        catch { diagnostic("Cannot save final job status: \(error.localizedDescription)"); return code == 0 ? 74 : code }
        return code
    }

    guard let executable = executableURL(command[0]) else {
        diagnostic("Executable not found: \(command[0])")
        return finish(status: "failed", code: 127)
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = Array(command.dropFirst())
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do { try process.run() }
    catch {
        diagnostic("Cannot start command: \(error.localizedDescription)")
        return finish(status: "failed", code: 126)
    }

    let cancellation = CancellationState()
    let signalQueue = DispatchQueue(label: "Broschy.signals")
    var sources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler {
            cancellation.record(number)
            if process.isRunning { kill(process.processIdentifier, number) }
        }
        source.resume()
        sources.append(source)
    }
    process.waitUntilExit()
    // Drain delivered signals before deciding whether this was a cancellation.
    signalQueue.sync {}
    for source in sources { source.cancel() }
    let terminatingSignal = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
    let wasCancelled = cancellation.signalNumber != nil || terminatingSignal == SIGINT || terminatingSignal == SIGTERM || terminatingSignal == SIGHUP
    let code: Int32 = terminatingSignal.map { 128 + $0 } ?? process.terminationStatus
    return finish(status: wasCancelled ? "cancelled" : (code == 0 ? "succeeded" : "failed"), code: code)
}

func notify(_ input: [String]) -> Int32 {
    var title: String?
    var status: String?
    var index = 0
    while index + 1 < input.count {
        switch input[index] {
        case "--title" where title == nil: title = input[index + 1]
        case "--status" where status == nil: status = input[index + 1]
        default: diagnostic("Expected --title \"Name\" --status succeeded|failed."); return 64
        }
        index += 2
    }
    guard index == input.count, let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          title.count <= 160, let status, ["succeeded", "failed"].contains(status) else {
        diagnostic("Expected a title of 1–160 characters and --status succeeded|failed.")
        return 64
    }
    let now = Date()
    let job = JobRecord(id: UUID().uuidString, title: title, status: status, startedAt: now, finishedAt: now, workingDirectory: FileManager.default.currentDirectoryPath)
    do { try writeJob(job, to: jobsDirectory()); return 0 }
    catch { diagnostic("Cannot save notification: \(error.localizedDescription)"); return 74 }
}

#if BROSCHY_TESTS
try MainActor.assumeIsolated { try CoreTests.main() }
#else
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || ["--help", "-h", "help"].contains(arguments[0]) {
    usage()
    exit(0)
}
switch arguments[0] {
case "run": exit(runCommand(Array(arguments.dropFirst())))
case "notify": exit(notify(Array(arguments.dropFirst())))
default: diagnostic("Unknown command. Use --help."); exit(64)
}
#endif

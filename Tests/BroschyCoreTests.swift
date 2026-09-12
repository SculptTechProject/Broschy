import Foundation
#if BROSCHY_TESTS
import Darwin
import Dispatch
#endif

#if !BROSCHY_TESTS
@main
#endif
enum CoreTests {
    @MainActor
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var timer = FlowTimerState()
        precondition(!timer.hasStarted && !timer.isRunning, "A new timer must be idle, not paused.")
        timer.start(minutes: 25, now: base)
        precondition(timer.hasStarted && timer.isRunning, "Starting must establish an active timer lifecycle.")
        timer.tick(now: base.addingTimeInterval(605.2))
        precondition(timer.remainingSeconds == 895, "Countdown must reflect elapsed wall time, including sleep.")
        timer.togglePause(now: base.addingTimeInterval(610))
        let paused = timer.remainingSeconds
        timer.tick(now: base.addingTimeInterval(10_000))
        precondition(timer.remainingSeconds == paused && !timer.isRunning && timer.hasStarted, "Paused time must stay frozen and remain an active lifecycle.")
        timer.togglePause(now: base.addingTimeInterval(10_000))
        timer.tick(now: base.addingTimeInterval(10_000 + Double(paused)))
        precondition(timer.remainingSeconds == 0 && timer.didFinish && !timer.isRunning && timer.hasStarted, "Resumed deadline must complete exactly and retain its lifecycle.")
        timer.tick(now: base.addingTimeInterval(50_000))
        precondition(timer.didFinish && timer.remainingSeconds == 0, "Completion should remain available until dismissed.")
        timer.dismissCompletion()
        precondition(!timer.didFinish && timer.remainingSeconds == 0 && timer.hasStarted)
        timer.reset()
        precondition(timer.remainingSeconds == 1_500 && timer.deadline == nil && !timer.isRunning && !timer.hasStarted, "Reset must return to idle, distinguishable from an immediate pause.")
        timer.start(minutes: 25, now: base)
        timer.togglePause(now: base)
        precondition(timer.hasStarted && !timer.isRunning && timer.remainingSeconds == timer.totalSeconds, "An immediate pause still belongs to a started timer.")

        timer.start(minutes: 1, now: base)
        timer.togglePause(now: base.addingTimeInterval(61))
        precondition(timer.didFinish && !timer.isRunning, "Pausing an overdue timer must finish it rather than resurrect it.")
        timer.start(minutes: 999, now: base)
        precondition(timer.totalSeconds == 10_800 && timer.isValid, "Extreme duration must be bounded.")
        timer.start(minutes: -2, now: base)
        precondition(timer.totalSeconds == 60 && timer.isValid)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored = try decoder.decode(FlowTimerState.self, from: encoder.encode(timer))
        precondition(restored.hasStarted && restored.isValid, "Started lifecycle must persist.")
        restored.tick(now: base.addingTimeInterval(90))
        precondition(restored.didFinish && restored.remainingSeconds == 0, "Restoring an expired deadline must finish the timer.")
        let legacyState = Data("{\"remainingSeconds\":1500,\"isRunning\":false,\"didFinish\":false,\"totalSeconds\":1500}".utf8)
        let legacy = try decoder.decode(FlowTimerState.self, from: legacyState)
        precondition(!legacy.hasStarted && legacy.isValid, "Existing state without hasStarted must still load.")
        print("PASS: lifecycle, elapsed/sleep, pause/resume, completion, reset, bounds, persisted deadline, legacy state")

        #if BROSCHY_TESTS
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass an isolated work directory for CLI integration checks.")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("broschy-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func record(named title: String) throws -> JobRecord {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            return try files.map { try decoder.decode(JobRecord.self, from: Data(contentsOf: $0)) }.first { $0.title == title }!
        }

        let literal = "$(touch NEVER_CREATE_ME); two words *"
        let literalPath = directory.appendingPathComponent(literal).path
        let success = runCommand(["--label", "Argument verification", "--", "/usr/bin/touch", literalPath], directoryOverride: directory)
        precondition(success == 0 && FileManager.default.fileExists(atPath: literalPath), "Arguments must reach the executable literally, including shell metacharacters and spaces.")
        let successJob = try record(named: "Argument verification")
        precondition(successJob.status == "succeeded" && successJob.exitCode == 0 && successJob.finishedAt != nil)
        let failure = runCommand(["--label", "Exit verification", "--", "/usr/bin/false"], directoryOverride: directory)
        let failedJob = try record(named: "Exit verification")
        precondition(failure == 1 && failedJob.status == "failed" && failedJob.exitCode == 1)
        let missing = runCommand(["--label", "Missing verification", "--", "/nonexistent/broschy-test-command"], directoryOverride: directory)
        let missingJob = try record(named: "Missing verification")
        precondition(missing == 127 && missingJob.status == "failed" && missingJob.finishedAt != nil, "Launch failure must not leave a running job.")
        let beforeInvalid = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        precondition(runCommand(["--label", "", "--", "/usr/bin/true"], directoryOverride: directory) == 64)
        let afterInvalid = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        precondition(beforeInvalid == afterInvalid, "Invalid input must not create a record or start a process.")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { kill(getpid(), SIGINT) }
        let cancelled = runCommand(["--label", "Cancellation verification", "--", "/bin/sleep", "5"], directoryOverride: directory)
        let cancelledJob = try record(named: "Cancellation verification")
        precondition(cancelled == 130 && cancelledJob.status == "cancelled" && cancelledJob.finishedAt != nil, "Ctrl-C must terminate the child and persist cancelled status.")
        print("PASS: literal argv, success, nonzero exit, launch failure, input validation, Ctrl-C final status")

        #if FLOW_STORE_TESTS
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let store = FlowStore(supportDirectory: storeDirectory, startTicker: false)
        store.taskTitle = String(repeating: "x", count: 200)
        store.note = String(repeating: "n", count: 5_000)
        store.saveNow()
        let reloaded = FlowStore(supportDirectory: storeDirectory, startTicker: false)
        precondition(reloaded.taskTitle.count == 160 && reloaded.note.count == 4_000, "Edited text must be bounded and survive relaunch.")
        reloaded.start(minutes: 1)
        let runningReload = FlowStore(supportDirectory: storeDirectory, startTicker: false)
        precondition(runningReload.timerState.hasStarted && runningReload.timerState.isRunning, "A running session must survive relaunch.")
        runningReload.tick(now: Date().addingTimeInterval(120))
        let completedReload = FlowStore(supportDirectory: storeDirectory, startTicker: false)
        precondition(completedReload.timerState.didFinish && completedReload.timerState.hasStarted, "Completion after sleep must be persisted.")

        let corrupt = Data("{broken state with an irreplaceable note".utf8)
        try corrupt.write(to: storeDirectory.appendingPathComponent("state.json"), options: .atomic)
        let recovered = FlowStore(supportDirectory: storeDirectory, startTicker: false)
        precondition(recovered.storageError != nil, "Invalid state must be reported.")
        recovered.taskTitle = "Recovered"
        recovered.saveNow()
        let backup = try FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("state-recovery-") }!
        let backupData = try Data(contentsOf: backup)
        precondition(backupData == corrupt && recovered.storageError != nil, "Corrupt state must be preserved exactly and the recovery notice retained.")
        let recoveredReload = FlowStore(supportDirectory: storeDirectory, startTicker: false)
        precondition(recoveredReload.taskTitle == "Recovered" && recoveredReload.storageError == nil, "Recovery must allow future valid saves.")
        print("PASS: bounded persisted text, active session relaunch, completion persistence, corrupt-state recovery")
        #endif
        #endif
    }
}

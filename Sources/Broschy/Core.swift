import Foundation

struct FlowJob: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case running, succeeded, failed, cancelled
    }

    let id: String
    let title: String
    let status: Status
    let startedAt: Date
    let finishedAt: Date?
    let exitCode: Int?
    let workingDirectory: String
}

/// Uses a wall-clock deadline so a sleeping Mac does not pause the countdown.
struct FlowTimerState: Codable, Equatable {
    private(set) var remainingSeconds = 25 * 60
    private(set) var isRunning = false
    private(set) var didFinish = false
    private(set) var hasStarted = false
    private(set) var totalSeconds = 25 * 60
    private(set) var deadline: Date?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case remainingSeconds, isRunning, didFinish, hasStarted, totalSeconds, deadline
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remainingSeconds = try values.decode(Int.self, forKey: .remainingSeconds)
        isRunning = try values.decode(Bool.self, forKey: .isRunning)
        didFinish = try values.decode(Bool.self, forKey: .didFinish)
        totalSeconds = try values.decode(Int.self, forKey: .totalSeconds)
        deadline = try values.decodeIfPresent(Date.self, forKey: .deadline)
        hasStarted = try values.decodeIfPresent(Bool.self, forKey: .hasStarted)
            ?? (isRunning || didFinish || remainingSeconds < totalSeconds)
    }

    mutating func start(minutes: Int, now: Date = Date()) {
        totalSeconds = min(max(minutes, 1), 180) * 60
        remainingSeconds = totalSeconds
        deadline = now.addingTimeInterval(TimeInterval(totalSeconds))
        isRunning = true
        didFinish = false
        hasStarted = true
    }

    mutating func tick(now: Date = Date()) {
        guard isRunning, let deadline else { return }
        let interval = deadline.timeIntervalSince(now)
        remainingSeconds = interval <= 0 ? 0 : min(totalSeconds, Int(ceil(interval)))
        if remainingSeconds == 0 {
            isRunning = false
            didFinish = true
            self.deadline = nil
        }
    }

    mutating func togglePause(now: Date = Date()) {
        if isRunning {
            tick(now: now)
            guard isRunning else { return }
            isRunning = false
            deadline = nil
        } else if remainingSeconds > 0 {
            deadline = now.addingTimeInterval(TimeInterval(remainingSeconds))
            isRunning = true
            didFinish = false
            hasStarted = true
        }
    }

    mutating func reset() {
        remainingSeconds = totalSeconds
        isRunning = false
        didFinish = false
        hasStarted = false
        deadline = nil
    }

    mutating func dismissCompletion() {
        didFinish = false
    }

    /// Validate persisted values before they become UI state.
    var isValid: Bool {
        (60...10_800).contains(totalSeconds)
            && (0...totalSeconds).contains(remainingSeconds)
            && (isRunning == (deadline != nil))
            && !(isRunning && didFinish)
            && (!isRunning || hasStarted)
            && (!didFinish || (hasStarted && remainingSeconds == 0))
            && (hasStarted || (remainingSeconds == totalSeconds && !isRunning && !didFinish))
    }
}

import CryptoKit
import Foundation

struct BuildWatchTarget: Codable, Equatable {
    let owner: String
    let repository: String
    let branch: String?
    let pullRequest: Int?

    var displayName: String { "\(owner)/\(repository)" + (pullRequest.map { " #\($0)" } ?? "") }
    var webURL: URL { URL(string: "https://github.com/\(owner)/\(repository)" + (pullRequest.map { "/pull/\($0)" } ?? "/actions"))! }
    var repositoryInput: String { pullRequest == nil ? "\(owner)/\(repository)" : webURL.absoluteString }
    var identity: String {
        let text = "\(owner.lowercased())/\(repository.lowercased())|\(branch ?? "default")|\(pullRequest.map(String.init) ?? "repo")"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ input: String, branch: String = "") throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 512 else { throw BuildWatchError.invalidTarget }
        var pieces: [String]
        if text.contains("://") {
            guard let url = URLComponents(string: text), url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  !url.percentEncodedPath.contains("%") else { throw BuildWatchError.invalidTarget }
            pieces = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        } else {
            pieces = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        }
        guard pieces.count == 2 || (pieces.count == 4 && pieces[2] == "pull"),
              validOwner(pieces[0]), validRepository(pieces[1]) else { throw BuildWatchError.invalidTarget }
        let pullRequest: Int?
        if pieces.count == 4 {
            guard let number = Int(pieces[3]), number > 0, number <= Int32.max,
                  String(number) == pieces[3] else { throw BuildWatchError.invalidTarget }
            pullRequest = number
        } else { pullRequest = nil }
        let ref = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.isEmpty || validBranch(ref) else { throw BuildWatchError.invalidBranch }
        return Self(owner: pieces[0], repository: pieces[1], branch: pullRequest == nil && !ref.isEmpty ? ref : nil, pullRequest: pullRequest)
    }

    var isValid: Bool {
        Self.validOwner(owner) && Self.validRepository(repository)
            && (branch == nil || Self.validBranch(branch!))
            && (pullRequest == nil || (pullRequest! > 0 && pullRequest! <= Int32.max && branch == nil))
    }

    static func validOwner(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil
    }
    static func validRepository(_ value: String) -> Bool {
        ![".", ".."].contains(value) && value.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil
    }
    static func validBranch(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && !value.hasPrefix("-")
            && !value.hasPrefix("/") && !value.hasSuffix("/") && !value.hasSuffix(".")
            && !value.contains("..") && !value.contains("//") && !value.contains("@{") && value != "@"
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: "~^:?*[\\")).contains($0) }
            && value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
    static func validSHA(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil
    }
}

enum BuildWatchRunStatus: String, Codable { case queued, inProgress = "in_progress", waiting, requested, pending, completed, unknown }
enum BuildWatchConclusion: String, Codable {
    case success, failure, neutral, cancelled, skipped, timedOut = "timed_out", actionRequired = "action_required"
    case stale, startupFailure = "startup_failure", unknown
}
enum BuildWatchRunState { case queued, running, waiting, success, failure, cancelled, skipped, neutral, unknown }

struct BuildWatchRun: Equatable, Identifiable {
    let id: Int64
    let name: String
    let headBranch: String
    let headSHA: String
    let htmlURL: URL
    let createdAt: Date
    let updatedAt: Date
    let status: BuildWatchRunStatus
    let conclusion: BuildWatchConclusion?
    let attempt: Int

    var completionKey: String { "\(id):\(attempt)" }
    var isActive: Bool { [.queued, .inProgress, .waiting, .requested, .pending].contains(status) }
    var isCompleted: Bool { status == .completed }
    var state: BuildWatchRunState {
        switch status {
        case .queued, .requested, .pending: return .queued
        case .inProgress: return .running
        case .waiting: return .waiting
        case .unknown: return .unknown
        case .completed:
            switch conclusion {
            case .success: return .success
            case .failure, .timedOut, .actionRequired, .startupFailure, .stale: return .failure
            case .cancelled: return .cancelled
            case .skipped: return .skipped
            case .neutral: return .neutral
            case .unknown, .none: return .unknown
            }
        }
    }
    var statusText: String {
        switch status {
        case .queued, .requested, .pending: return "Queued"
        case .inProgress: return "Running"
        case .waiting: return "Waiting for approval"
        case .unknown: return "Status unavailable"
        case .completed:
            switch conclusion {
            case .success: return "Passed"
            case .failure, .startupFailure: return "Failed"
            case .timedOut: return "Timed out"
            case .actionRequired: return "Action required"
            case .stale: return "Stale"
            case .cancelled: return "Cancelled"
            case .skipped: return "Skipped"
            case .neutral: return "Neutral"
            case .unknown, .none: return "Conclusion unavailable"
            }
        }
    }

    static func validatedURL(_ value: String, target: BuildWatchTarget, id: Int64) -> URL? {
        guard let components = URLComponents(string: value), components.scheme == "https",
              components.host?.lowercased() == "github.com", components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil,
              components.percentEncodedPath.lowercased() == "/\(target.owner)/\(target.repository)/actions/runs/\(id)".lowercased() else { return nil }
        return components.url
    }
}

struct BuildWatchCompletion: Equatable {
    let run: BuildWatchRun
    let observedAt: Date
}

enum BuildWatchConnectionStatus { case disconnected, connecting, connected, failure }
enum BuildWatchError: Error, Equatable {
    case invalidTarget, invalidBranch, missingCLI, authentication, forbidden, notFound, timedOut, cancelled, oversized, invalidResponse, network
    var message: String {
        switch self {
        case .invalidTarget: return "Enter owner/repository or a GitHub pull request URL."
        case .invalidBranch: return "Enter a valid branch name, or leave it blank for the default branch."
        case .missingCLI: return "Install GitHub CLI, then sign in with gh auth login."
        case .authentication: return "Sign in to GitHub CLI with gh auth login, then try again."
        case .forbidden: return "GitHub denied access or reached a rate limit. Check this account’s repository access."
        case .notFound: return "Repository or pull request not found. Check the target and your GitHub access."
        case .timedOut: return "GitHub took too long to respond. Broschy will try again."
        case .oversized, .invalidResponse: return "GitHub returned an unreadable response. Broschy will try again."
        case .cancelled: return "Watch stopped."
        case .network: return "Could not reach GitHub. Check your connection and GitHub CLI sign-in."
        }
    }
}

struct BuildWatchRequest { let target: BuildWatchTarget; let generation: Int }
struct BuildWatchSnapshot {
    let runs: [BuildWatchRun]
    let resolvedBranch: String
    /// Branch for a repository, exact head SHA for a PR. Changing PR heads must
    /// never celebrate a completed workflow from the previous commit.
    let scopeIdentity: String
}
enum BuildWatchOutcome { case success(BuildWatchSnapshot), failure(BuildWatchError) }

import AppKit
import Combine
import CoreServices

struct SpotifySnapshot: Equatable {
    var id: String = ""
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var volume: Int
}

enum SpotifyConnectionStatus: Equatable {
    case disconnected, notInstalled, notRunning, needsPermission, denied, connected, failure
}

/// A connection is opt-in. Only Connect may request Automation consent; polling never does.
@MainActor
final class SpotifyController: ObservableObject {
    @Published private(set) var snapshot: SpotifySnapshot?
    @Published private(set) var status: SpotifyConnectionStatus = .disconnected
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "Broschy.Spotify", qos: .utility)
    private let cancellation = SpotifyCancellation()
    private let perform: (SpotifyRequest, SpotifyCancellation) -> SpotifyOutcome
    private var generation = 0
    private var inFlight = false
    private var pendingRequest: SpotifyRequest?
    private var ticker: Timer?
    private var lastRefresh = Date.distantPast

    init(defaults: UserDefaults = .standard, startTicker: Bool = true,
         perform: @escaping (SpotifyRequest, SpotifyCancellation) -> SpotifyOutcome = SpotifyAppleEvents.perform) {
        self.defaults = defaults
        self.perform = perform
        isEnabled = defaults.bool(forKey: "spotifyIntegrationEnabled")
        if startTicker {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
            if isEnabled { refresh() }
        }
    }

    #if SPOTIFY_TESTS
    /// UI fixtures use no events, polling, or preference writes.
    convenience init(snapshot: SpotifySnapshot?) {
        self.init(startTicker: false, perform: { _, _ in SpotifyOutcome(status: .connected, snapshot: snapshot) })
        self.snapshot = snapshot
        self.status = .connected
        self.isEnabled = true
    }
    #endif

    deinit {
        ticker?.invalidate()
        cancellation.invalidate()
    }

    func connect() {
        isEnabled = true
        defaults.set(true, forKey: "spotifyIntegrationEnabled")
        submit(.refresh, requestConsent: true)
    }

    func disconnect() {
        generation += 1
        cancellation.setGeneration(generation)
        pendingRequest = nil
        isEnabled = false
        defaults.set(false, forKey: "spotifyIntegrationEnabled")
        snapshot = nil
        status = .disconnected
        errorMessage = nil
        busy = false
        // An already-sent event cannot be recalled. Keep the serial slot occupied until it returns.
    }

    func refresh() {
        guard isEnabled else { return }
        submit(.refresh)
    }

    func playPause() { command(.playPause) }
    func nextTrack() { command(.next) }
    func previousTrack() { command(.previous) }

    func seek(to position: Double) {
        guard let snapshot, !snapshot.id.isEmpty, position.isFinite, snapshot.duration > 0 else { return }
        command(.seek(min(max(0, position), snapshot.duration), expectedTrackID: snapshot.id))
    }

    func setVolume(_ volume: Int) { command(.volume(min(max(0, volume), 100))) }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyAppleEvents.bundleID) else {
            status = .notInstalled
            snapshot = nil
            return
        }
        // This method is called only by the visible Open Spotify button.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.status = .failure
                    self.snapshot = nil
                    self.errorMessage = "Could not open Spotify (\((error as NSError).code))."
                } else if self.isEnabled {
                    self.refresh()
                }
            }
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tick() {
        guard isEnabled, !inFlight else { return }
        let interval: TimeInterval = status == .connected ? 1 : 5
        if Date().timeIntervalSince(lastRefresh) >= interval { refresh() }
    }

    private func command(_ action: SpotifyAction) {
        guard isEnabled, status == .connected, snapshot != nil else { return }
        submit(action)
    }

    private func submit(_ action: SpotifyAction, requestConsent: Bool = false) {
        let request = SpotifyRequest(action: action, requestConsent: requestConsent, generation: generation)
        if inFlight {
            // A poll does not disable the controls. Preserve the latest user action until
            // the serial worker is free; routine refreshes never accumulate in the queue.
            if action != .refresh || requestConsent {
                pendingRequest = request
                busy = true
            }
            return
        }
        inFlight = true
        busy = action != .refresh || requestConsent
        lastRefresh = Date()
        let worker = perform
        let cancellation = cancellation
        queue.async { [weak self] in
            let outcome = worker(request, cancellation)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if self.generation == request.generation, self.isEnabled {
                    self.busy = false
                    self.status = outcome.status
                    self.snapshot = outcome.status == .connected ? outcome.snapshot : nil
                    self.errorMessage = outcome.errorMessage
                }
                let pending = self.pendingRequest
                self.pendingRequest = nil
                if let pending, self.isEnabled, pending.generation == self.generation {
                    self.submit(pending.action, requestConsent: pending.requestConsent)
                }
            }
        }
    }
}

enum SpotifyAction: Equatable {
    case refresh, playPause, next, previous, seek(Double, expectedTrackID: String), volume(Int)
}

struct SpotifyRequest {
    var action: SpotifyAction
    var requestConsent: Bool
    var generation: Int
}

struct SpotifyOutcome {
    var status: SpotifyConnectionStatus
    var snapshot: SpotifySnapshot? = nil
    var errorMessage: String? = nil
}

/// Checked between events, including after the system consent sheet returns.
final class SpotifyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var invalidated = false

    func setGeneration(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        generation = value
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidated = true
    }

    func allows(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !invalidated && generation == value
    }
}

/// Native Apple events, addressed to an existing process rather than a bundle ID.
/// No shell, AppleScript, ScriptingBridge auto-launch, or network calls are involved.
enum SpotifyAppleEvents {
    static let bundleID = "com.spotify.client"
    private static let timeout: TimeInterval = 1.5

    static func perform(_ request: SpotifyRequest, cancellation: SpotifyCancellation) -> SpotifyOutcome {
        guard cancellation.allows(request.generation) else { return SpotifyOutcome(status: .disconnected) }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return SpotifyOutcome(status: .notInstalled)
        }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !application.isTerminated else { return SpotifyOutcome(status: .notRunning) }
        let target = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
        guard let descriptor = target.aeDesc else {
            return SpotifyOutcome(status: .failure, errorMessage: "Could not address the Spotify process.")
        }
        let permission = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, request.requestConsent)
        guard cancellation.allows(request.generation) else { return SpotifyOutcome(status: .disconnected) }
        guard permission == noErr else { return failure(permission) }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let exchange: Exchange = { eventClass, eventID, object, value in
                guard cancellation.allows(request.generation) else { throw SpotifyEventError.cancelled }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SpotifyEventError.appleEvent(OSStatus(errAETimeout)) }
                return try send(target: target, eventClass: eventClass, eventID: eventID, object: object, value: value,
                                timeout: min(timeout, remaining))
            }
            return try execute(request.action, exchange: exchange)
        } catch SpotifyEventError.cancelled {
            return SpotifyOutcome(status: .disconnected)
        } catch SpotifyEventError.appleEvent(let status) {
            return failure(status)
        } catch {
            return failure(OSStatus((error as NSError).code))
        }
    }

    typealias Exchange = (AEEventClass, AEEventID, NSAppleEventDescriptor?, NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor

    /// Kept separate from permission and process lookup so command behavior can be tested without Spotify.
    static func execute(_ action: SpotifyAction, exchange: Exchange) throws -> SpotifyOutcome {
        switch action {
        case .refresh: break
        case .playPause: _ = try exchange(code("spfy"), code("PlPs"), nil, nil)
        case .next: _ = try exchange(code("spfy"), code("Next"), nil, nil)
        case .previous: _ = try exchange(code("spfy"), code("Prev"), nil, nil)
        case .seek(let seconds, let expectedID):
            let currentID: String?
            do {
                currentID = try exchange(kAECoreSuite, kAEGetData, property(code("ID  "), in: property(code("pTrk"))), nil).stringValue
            } catch SpotifyEventError.appleEvent(let status) where status == OSStatus(errAENoSuchObject) {
                currentID = nil
            }
            // A track can change while the user drags the timeline. Never seek the new track.
            if currentID == expectedID {
                _ = try exchange(kAECoreSuite, kAESetData, property(code("pPos")), NSAppleEventDescriptor(double: seconds))
            }
        case .volume(let volume):
            _ = try exchange(kAECoreSuite, kAESetData, property(code("pVol")), NSAppleEventDescriptor(int32: Int32(volume)))
        }

        // Retry only the read phase when a track changes during metadata collection.
        // Playback commands above must never be repeated by a refresh retry.
        for attempt in 0..<2 {
            let player = NSAppleEventDescriptor.record()
            func readPlayer(_ key: OSType) throws -> NSAppleEventDescriptor {
                let value = try exchange(kAECoreSuite, kAEGetData, property(key), nil)
                player.setDescriptor(value, forKeyword: key)
                return value
            }
            let state = try readPlayer(code("pPlS"))
            _ = try readPlayer(code("pVol"))
            guard [code("kPSS"), code("kPSP"), code("kPSp")].contains(state.enumCodeValue) else {
                return SpotifyOutcome(status: .failure, errorMessage: "Spotify did not return its player state. Try connecting again.")
            }
            if state.enumCodeValue == code("kPSS") {
                return SpotifyOutcome(status: .connected, snapshot: emptySnapshot(player: player))
            }
            _ = try readPlayer(code("pPos"))

            let track = NSAppleEventDescriptor.record()
            func readTrack(_ key: OSType) throws -> NSAppleEventDescriptor {
                try exchange(kAECoreSuite, kAEGetData, property(key, in: property(code("pTrk"))), nil)
            }
            do {
                let identity = try readTrack(code("ID  "))
                guard let initialID = identity.stringValue, !initialID.isEmpty else {
                    return SpotifyOutcome(status: .connected, snapshot: emptySnapshot(player: player))
                }
                track.setDescriptor(identity, forKeyword: code("ID  "))
                track.setDescriptor(try readTrack(code("pnam")), forKeyword: code("pnam"))

                // Spotify's aggregate track properties include obsolete fields (for example
                // starred) that fail with -10000. Request only what this player displays.
                // Optional metadata failures do not make working playback controls disappear.
                for key in [code("pArt"), code("pAlb"), code("pDur"), code("aUrl")] {
                    let value: NSAppleEventDescriptor
                    do {
                        value = try readTrack(key)
                    } catch SpotifyEventError.appleEvent(let status) where unavailableProperty(status) {
                        value = key == code("pDur") ? .init(double: 0) : .init(string: "")
                    }
                    track.setDescriptor(value, forKeyword: key)
                }
                let finalID = try readTrack(code("ID  ")).stringValue
                if finalID == initialID {
                    return SpotifyOutcome(status: .connected, snapshot: try snapshot(player: player, track: track))
                }
                if attempt == 1 {
                    return SpotifyOutcome(status: .connected, snapshot: emptySnapshot(player: player))
                }
            } catch SpotifyEventError.appleEvent(let status) where status == OSStatus(errAENoSuchObject) {
                return SpotifyOutcome(status: .connected, snapshot: emptySnapshot(player: player))
            }
        }
        return SpotifyOutcome(status: .failure, errorMessage: "Spotify is updating its current track. Try again in a moment.")
    }

    private static func unavailableProperty(_ status: OSStatus) -> Bool {
        [OSStatus(errAEEventFailed), OSStatus(errAENoSuchObject),
         OSStatus(errAEEventNotHandled), OSStatus(errAECoercionFail)].contains(status)
    }

    static func failure(_ status: OSStatus) -> SpotifyOutcome {
        switch status {
        case OSStatus(errAEEventWouldRequireUserConsent): return SpotifyOutcome(status: .needsPermission)
        case OSStatus(errAEEventNotPermitted): return SpotifyOutcome(status: .denied)
        case OSStatus(procNotFound), OSStatus(connectionInvalid): return SpotifyOutcome(status: .notRunning)
        case OSStatus(errAETimeout):
            return SpotifyOutcome(status: .failure, errorMessage: "Spotify took too long to respond. Try again in a moment.")
        default:
            return SpotifyOutcome(status: .failure, errorMessage: "Could not communicate with Spotify (\(status)).")
        }
    }

    static func snapshot(player: NSAppleEventDescriptor, track: NSAppleEventDescriptor) throws -> SpotifySnapshot? {
        let title = track.forKeyword(code("pnam"))?.stringValue ?? ""
        guard !title.isEmpty else { return emptySnapshot(player: player) }
        guard let state = player.forKeyword(code("pPlS")),
              let positionDescriptor = player.forKeyword(code("pPos")),
              let volumeDescriptor = player.forKeyword(code("pVol")),
              let durationDescriptor = track.forKeyword(code("pDur")) else {
            throw SpotifyEventError.appleEvent(OSStatus(errAECorruptData))
        }
        // Spotify's desktop scripting interface returns track duration in milliseconds,
        // although older bundled dictionaries describe seconds. Player position is seconds.
        let rawDuration = durationDescriptor.doubleValue / 1_000
        let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        let rawPosition = positionDescriptor.doubleValue
        let position = rawPosition.isFinite ? min(max(0, rawPosition), duration) : 0
        return SpotifySnapshot(
            id: String((track.forKeyword(code("ID  "))?.stringValue ?? "").prefix(500)),
            title: String(title.prefix(500)),
            artist: String((track.forKeyword(code("pArt"))?.stringValue ?? "").prefix(500)),
            album: String((track.forKeyword(code("pAlb"))?.stringValue ?? "").prefix(500)),
            artworkURL: artworkURL(track.forKeyword(code("aUrl"))?.stringValue),
            duration: duration, position: position,
            isPlaying: state.enumCodeValue == code("kPSP"),
            volume: min(max(0, Int(volumeDescriptor.int32Value)), 100)
        )
    }

    static func artworkURL(_ value: String?) -> URL? {
        guard let value, value.count <= 2_048, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host == "scdn.co" || host.hasSuffix(".scdn.co") || host == "spotifycdn.com" || host.hasSuffix(".spotifycdn.com") else { return nil }
        return url
    }

    private static func emptySnapshot(player: NSAppleEventDescriptor) -> SpotifySnapshot {
        SpotifySnapshot(title: "", artist: "", album: "", artworkURL: nil, duration: 0, position: 0,
                        isPlaying: false, volume: min(max(0, Int(player.forKeyword(code("pVol"))?.int32Value ?? 50)), 100))
    }

    static func property(_ identifier: OSType, in container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: cProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: identifier), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    static func code(_ string: StaticString) -> OSType {
        string.withUTF8Buffer { bytes in bytes.reduce(0) { ($0 << 8) | OSType($1) } }
    }

    private static func send(target: NSAppleEventDescriptor, eventClass: AEEventClass, eventID: AEEventID,
                             object: NSAppleEventDescriptor?, value: NSAppleEventDescriptor?,
                             timeout eventTimeout: TimeInterval = 1.5) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: target,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        if let value { event.setParam(value, forKeyword: keyAEData) }
        // The permission preflight can race with a user revoking consent. This flag prevents
        // the event itself from showing a prompt even in that race.
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract,
            .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: options, timeout: eventTimeout)
        } catch {
            let error = error as NSError
            guard error.domain == NSOSStatusErrorDomain else { throw error }
            throw SpotifyEventError.appleEvent(OSStatus(error.code))
        }
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            throw SpotifyEventError.appleEvent(error.int32Value)
        }
        return reply.paramDescriptor(forKeyword: keyAEResult) ?? .null()
    }
}

enum SpotifyEventError: Error {
    case cancelled
    case appleEvent(OSStatus)
}

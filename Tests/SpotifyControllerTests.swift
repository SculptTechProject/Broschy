import AppKit
import CoreServices

/// Run with SpotifyController.swift only. No events are sent and Spotify is not launched.
@main
struct SpotifyControllerTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func record(_ values: [(StaticString, NSAppleEventDescriptor)]) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (key, value) in values { record.setDescriptor(value, forKeyword: SpotifyAppleEvents.code(key)) }
        return record
    }

    static func player(position: Double = 12, state: StaticString = "kPSP") -> NSAppleEventDescriptor {
        record([("pPlS", .init(enumCode: SpotifyAppleEvents.code(state))),
                ("pPos", .init(double: position)), ("pVol", .init(int32: 135))])
    }

    static func track(title: String = "Test song", duration: Double = 240_000) -> NSAppleEventDescriptor {
        record([("ID  ", .init(string: "spotify:track:test")), ("pnam", .init(string: title)),
                ("pArt", .init(string: "Artist")), ("pAlb", .init(string: "Album")),
                ("pDur", .init(double: duration)), ("aUrl", .init(string: "https://i.scdn.co/image/test"))])
    }

    @MainActor
    static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(false, "Timed out waiting for fake worker")
    }

    @MainActor
    static func main() async throws {
        let code = SpotifyAppleEvents.code
        let object = SpotifyAppleEvents.property(code("pPos"))
        expect(object.descriptorType == typeObjectSpecifier, "Property must be an object specifier")
        expect(object.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == cProperty, "Wrong desired class")
        expect(object.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formPropertyID), "Wrong property form")
        expect(object.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == code("pPos"), "Wrong property code")
        expect(object.forKeyword(AEKeyword(keyAEContainer))?.descriptorType == typeNull, "App property must have null container")

        let parsed = try SpotifyAppleEvents.snapshot(player: player(), track: track())!
        expect(parsed.id == "spotify:track:test", "Track identity lost")
        expect(parsed.duration == 240 && parsed.position == 12, "Duration must be milliseconds; position seconds")
        expect(parsed.volume == 100 && parsed.isPlaying, "Volume must be clamped and playing parsed")
        expect(parsed.artworkURL?.host == "i.scdn.co", "Valid Spotify art missing")
        let clamped = try SpotifyAppleEvents.snapshot(player: player(position: 999), track: track())!
        expect(clamped.position == 240, "Position must not exceed duration")
        let invalid = try SpotifyAppleEvents.snapshot(player: player(position: .nan), track: track(duration: -.infinity))!
        expect(invalid.position == 0 && invalid.duration == 0, "Non-finite slider values must not escape")
        let empty = try SpotifyAppleEvents.snapshot(player: player(), track: track(title: ""))!
        expect(empty.title.isEmpty && empty.id.isEmpty && !empty.isPlaying && empty.duration == 0, "Empty player must remain connected and safe")
        for rejected in ["file:///private/test", "http://i.scdn.co/test", "https://i.scdn.co.evil.example/test", "https://user:pass@i.scdn.co/test", "https://localhost/test"] {
            expect(SpotifyAppleEvents.artworkURL(rejected) == nil, "Artwork URL not validated: \(rejected)")
        }
        expect(SpotifyAppleEvents.failure(OSStatus(errAEEventWouldRequireUserConsent)).status == .needsPermission, "Consent-required mapping")
        expect(SpotifyAppleEvents.failure(OSStatus(errAEEventNotPermitted)).status == .denied, "Consent-denied mapping")
        expect(SpotifyAppleEvents.failure(OSStatus(procNotFound)).status == .notRunning, "Missing-process mapping")
        expect(SpotifyAppleEvents.failure(OSStatus(errAETimeout)).snapshot == nil, "Failures must clear controls")

        // Model Spotify's actual compatibility failure: pALL is unsupported, while explicit
        // app properties and properties nested under current track are available.
        let explicitReads = StrictSpotifyExchange()
        let acquired = try SpotifyAppleEvents.execute(.refresh, exchange: explicitReads.exchange)
        expect(acquired.status == .connected && acquired.snapshot == parsed, "Explicit property reads must produce the complete current track")
        expect(explicitReads.commands.isEmpty && explicitReads.writes.isEmpty, "Refreshing must never change playback")
        expect(!explicitReads.reads.contains { $0.code == code("pALL") || $0.code == code("spSt") }, "Polling must not request unsupported bulk or starred properties")

        let stopped = StrictSpotifyExchange()
        stopped.state = "kPSS"
        let stoppedOutcome = try SpotifyAppleEvents.execute(.refresh, exchange: stopped.exchange)
        expect(stoppedOutcome.status == .connected && stoppedOutcome.snapshot?.id.isEmpty == true, "Stopped playback should remain connected")
        expect(!stopped.reads.contains { $0.isTrack }, "Stopped playback must not query an absent track")

        // Test the real command encoder against a strict fake, never a player.
        for (action, expectedEvent) in [(SpotifyAction.playPause, code("PlPs")), (.next, code("Next")), (.previous, code("Prev"))] {
            let fake = StrictSpotifyExchange()
            _ = try SpotifyAppleEvents.execute(action, exchange: fake.exchange)
            expect(fake.commands == [expectedEvent], "Spotify command must be sent exactly once")
        }
        for matches in [false, true] {
            let fake = StrictSpotifyExchange()
            fake.identityReplies = [matches ? "original" : "new-track"]
            _ = try SpotifyAppleEvents.execute(.seek(31, expectedTrackID: "original"), exchange: fake.exchange)
            expect(fake.writes.count == (matches ? 1 : 0), "A stale seek must not affect another track")
            if matches {
                expect(fake.writes[0].code == code("pPos") && fake.writes[0].value.doubleValue == 31, "Seek must write seconds to player position")
            }
        }

        let noArtwork = StrictSpotifyExchange()
        noArtwork.failingReads[code("aUrl")] = .appleEvent(OSStatus(errAEEventFailed))
        let withoutArtwork = try SpotifyAppleEvents.execute(.next, exchange: noArtwork.exchange)
        expect(withoutArtwork.status == .connected && withoutArtwork.snapshot?.title == "Test song", "Unavailable optional artwork must not disable playback controls")
        expect(withoutArtwork.snapshot?.artworkURL == nil && noArtwork.commands == [code("Next")], "Optional read recovery must not replay Next")

        let failedRead = StrictSpotifyExchange()
        failedRead.failingReads[code("pPlS")] = .appleEvent(OSStatus(errAEEventFailed))
        expectAppleEvent(OSStatus(errAEEventFailed)) {
            _ = try SpotifyAppleEvents.execute(.next, exchange: failedRead.exchange)
        }
        expect(failedRead.commands == [code("Next")], "A failed mandatory read must never replay a successful command")

        for errorCode in [OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAETimeout), OSStatus(procNotFound)] {
            let interrupted = StrictSpotifyExchange()
            interrupted.failingReads[code("aUrl")] = .appleEvent(errorCode)
            expectAppleEvent(errorCode) { _ = try SpotifyAppleEvents.execute(.refresh, exchange: interrupted.exchange) }
        }
        let cancelled = StrictSpotifyExchange()
        cancelled.failingReads[code("aUrl")] = .cancelled
        do {
            _ = try SpotifyAppleEvents.execute(.refresh, exchange: cancelled.exchange)
            expect(false, "Cancellation must not be swallowed by optional metadata reads")
        } catch SpotifyEventError.cancelled { }

        let changedTrack = StrictSpotifyExchange()
        changedTrack.identityReplies = ["old-track", "new-track", "new-track", "new-track"]
        changedTrack.titlesByID = ["old-track": "Old song", "new-track": "New song"]
        let refreshedTrack = try SpotifyAppleEvents.execute(.next, exchange: changedTrack.exchange)
        expect(refreshedTrack.snapshot?.id == "new-track" && refreshedTrack.snapshot?.title == "New song", "Track changes during metadata reads must retry the read for one coherent track")
        expect(changedTrack.commands == [code("Next")] && changedTrack.identityReadCount == 4, "Snapshot consistency retry must be bounded and must never repeat Next")

        let changingContinuously = StrictSpotifyExchange()
        changingContinuously.identityReplies = ["one", "two", "three", "four"]
        let inconsistent = try SpotifyAppleEvents.execute(.next, exchange: changingContinuously.exchange)
        expect(inconsistent.status == .connected && inconsistent.snapshot?.id.isEmpty == true, "Two inconsistent reads must not publish mixed track metadata")
        expect(changingContinuously.identityReadCount == 4 && changingContinuously.commands == [code("Next")], "Unstable playback must not cause an unbounded retry or repeated command")

        let vanishedTrack = StrictSpotifyExchange()
        vanishedTrack.failingReads[code("ID  ")] = .appleEvent(OSStatus(errAENoSuchObject))
        let vanished = try SpotifyAppleEvents.execute(.refresh, exchange: vanishedTrack.exchange)
        expect(vanished.status == .connected && vanished.snapshot?.id.isEmpty == true, "A track disappearing during refresh should clear stale controls without disconnecting")

        let unavailableDuration = StrictSpotifyExchange()
        unavailableDuration.failingReads[code("pDur")] = .appleEvent(OSStatus(errAEEventFailed))
        let noDuration = try SpotifyAppleEvents.execute(.refresh, exchange: unavailableDuration.exchange)
        expect(noDuration.status == .connected && noDuration.snapshot?.title == "Test song" && noDuration.snapshot?.duration == 0,
               "Unavailable duration must leave transport available with a safe disabled timeline")

        let suite = "Broschy.SpotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = FakeSpotifyWorker(snapshot: parsed)
        let controller = SpotifyController(defaults: defaults, startTicker: false, perform: worker.perform)
        expect(!controller.isEnabled && worker.count == 0, "Initialization must not communicate or opt in")
        controller.connect()
        await eventually { controller.status == .connected && !controller.busy }
        expect(worker.requests[0].requestConsent, "Only explicit connection should request permission")
        expect(defaults.bool(forKey: "spotifyIntegrationEnabled"), "Explicit connection must persist opt-in")

        worker.blockNext()
        controller.refresh()
        await eventually { worker.count == 2 }
        expect(!controller.busy, "Polling must not flash disabled controls")
        controller.playPause()
        expect(controller.busy, "Deferred user command should be busy")
        controller.refresh()
        worker.release()
        await eventually { worker.count == 3 && !controller.busy }
        expect(worker.requests[2].action == .playPause, "User action was lost during polling")
        expect(!worker.requests[1].requestConsent && !worker.requests[2].requestConsent, "Polling and commands must not prompt")
        expect(worker.maximumConcurrent == 1, "Commands overlapped")

        worker.blockNext()
        controller.refresh()
        await eventually { worker.count == 4 }
        controller.nextTrack()
        controller.disconnect()
        expect(controller.snapshot == nil && !controller.busy && controller.status == .disconnected, "Disconnect must immediately clear controls")
        worker.release()
        await eventually { worker.completed == 4 }
        try? await Task.sleep(for: .milliseconds(50))
        expect(worker.count == 4 && controller.snapshot == nil, "Late reply or pending command escaped disconnect")
        expect(!defaults.bool(forKey: "spotifyIntegrationEnabled"), "Disconnect must clear opt-in")
        controller.connect()
        await eventually { worker.count == 5 && controller.status == .connected && !controller.busy }
        expect(worker.requests[4].generation == 1, "Reconnect reused cancelled generation")
        controller.setVolume(130)
        await eventually { worker.count == 6 && !controller.busy }
        expect(worker.requests[5].action == .volume(100), "User volume must be clamped")
        controller.seek(to: 9_999)
        await eventually { worker.count == 7 && !controller.busy }
        expect(worker.requests[6].action == .seek(240, expectedTrackID: parsed.id), "Seek must capture identity and clamp")
        worker.blockNext()
        controller.refresh()
        await eventually { worker.count == 8 }
        controller.nextTrack()
        controller.disconnect()
        controller.connect()
        expect(controller.busy, "Reconnect should stay visibly busy while the old operation exits")
        worker.release()
        await eventually { worker.count == 9 && controller.status == .connected && !controller.busy }
        expect(worker.requests[8].action == .refresh && worker.requests[8].requestConsent && worker.requests[8].generation == 2,
               "Immediate reconnect replayed an old pending command")
        controller.disconnect()
        print("Spotify tests passed: strict explicit property reads, unsupported bulk properties, optional metadata failures, consistent track retry, command mapping, stale seek, queued actions, cancellation, opt-in, and serialization. No live Apple events sent.")
    }

    static func expectAppleEvent(_ expected: OSStatus, operation: () throws -> Void) {
        do {
            try operation()
            expect(false, "Expected Apple event error \(expected)")
        } catch SpotifyEventError.appleEvent(let actual) {
            expect(actual == expected, "Apple event error was changed or swallowed: \(actual)")
        } catch {
            expect(false, "Unexpected error: \(error)")
        }
    }
}

/// Fails closed on unknown events or malformed app/track containers. The fixture deliberately
/// models Spotify's failing bulk accessor instead of fabricating a supported pALL response.
private final class StrictSpotifyExchange {
    struct Property {
        let code: OSType
        let isTrack: Bool
    }
    struct Write {
        let code: OSType
        let value: NSAppleEventDescriptor
    }
    var state: StaticString = "kPSP"
    var identityReplies = ["spotify:track:test"]
    var titlesByID: [String: String] = [:]
    var failingReads: [OSType: SpotifyEventError] = [:]
    private(set) var commands: [AEEventID] = []
    private(set) var writes: [Write] = []
    private(set) var reads: [Property] = []
    private(set) var identityReadCount = 0
    private var currentID = "spotify:track:test"

    func exchange(_ eventClass: AEEventClass, _ eventID: AEEventID,
                  _ object: NSAppleEventDescriptor?, _ value: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        let code = SpotifyAppleEvents.code
        let expect = SpotifyControllerTests.expect
        if eventClass == code("spfy") {
            expect([code("Next"), code("Prev"), code("PlPs")].contains(eventID), "Unexpected playback command")
            expect(object == nil && value == nil, "Transport command should not include a property")
            commands.append(eventID)
            return .null()
        }
        expect(eventClass == kAECoreSuite, "Unexpected Apple event class")
        guard let object else { fatalError("Property event must identify its object") }
        let property = classify(object)
        if eventID == kAESetData {
            expect(!property.isTrack && [code("pPos"), code("pVol")].contains(property.code), "Unexpected writable property")
            guard let value else { fatalError("Property write has no value") }
            writes.append(Write(code: property.code, value: value))
            return .null()
        }
        expect(eventID == kAEGetData && value == nil, "Unexpected property event")
        reads.append(property)
        if property.code == code("pALL") || property.code == code("spSt") {
            throw SpotifyEventError.appleEvent(OSStatus(errAEEventFailed))
        }
        if let error = failingReads[property.code] { throw error }
        if property.isTrack {
            switch property.code {
            case code("ID  "):
                identityReadCount += 1
                if !identityReplies.isEmpty {
                    currentID = identityReplies.count > 1 ? identityReplies.removeFirst() : identityReplies[0]
                }
                return .init(string: currentID)
            case code("pnam"): return .init(string: titlesByID[currentID] ?? "Test song")
            case code("pArt"): return .init(string: "Artist")
            case code("pAlb"): return .init(string: "Album")
            case code("pDur"): return .init(int32: 240_000)
            case code("aUrl"): return .init(string: "https://i.scdn.co/image/test")
            default: fatalError("Unexpected property inside current track: \(property.code)")
            }
        }
        switch property.code {
        case code("pPlS"): return .init(enumCode: code(state))
        case code("pPos"): return .init(double: 12)
        case code("pVol"): return .init(int32: 135)
        default: fatalError("Unexpected application property: \(property.code)")
        }
    }

    private func classify(_ object: NSAppleEventDescriptor) -> Property {
        let code = SpotifyAppleEvents.code
        let expect = SpotifyControllerTests.expect
        expect(object.descriptorType == typeObjectSpecifier, "Requested property is not an object specifier")
        expect(object.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == cProperty, "Requested object is not a property")
        expect(object.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formPropertyID), "Requested property has wrong selector form")
        guard let identifier = object.forKeyword(AEKeyword(keyAEKeyData)),
              let container = object.forKeyword(AEKeyword(keyAEContainer)) else { fatalError("Incomplete property specifier") }
        if container.descriptorType == typeNull { return Property(code: identifier.typeCodeValue, isTrack: false) }
        let parent = classify(container)
        expect(!parent.isTrack && parent.code == code("pTrk"), "Track properties must be nested directly inside current track")
        return Property(code: identifier.typeCodeValue, isTrack: true)
    }
}

private final class FakeSpotifyWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let snapshot: SpotifySnapshot
    private var shouldBlock = false
    private var storedRequests: [SpotifyRequest] = []
    private var active = 0
    private var maximum = 0
    private var finished = 0

    init(snapshot: SpotifySnapshot) { self.snapshot = snapshot }

    var requests: [SpotifyRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    var count: Int { requests.count }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return finished }
    var maximumConcurrent: Int { lock.lock(); defer { lock.unlock() }; return maximum }

    func blockNext() { lock.lock(); shouldBlock = true; lock.unlock() }
    func release() { gate.signal() }

    func perform(_ request: SpotifyRequest, cancellation: SpotifyCancellation) -> SpotifyOutcome {
        lock.lock()
        storedRequests.append(request)
        active += 1
        maximum = max(maximum, active)
        let blocking = shouldBlock
        shouldBlock = false
        lock.unlock()
        if blocking { _ = gate.wait(timeout: .now() + 3) }
        lock.lock()
        active -= 1
        finished += 1
        lock.unlock()
        // Intentionally ignore cancellation here to test the controller's stale-result guard.
        return SpotifyOutcome(status: .connected, snapshot: snapshot)
    }
}

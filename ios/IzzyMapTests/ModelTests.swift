import CoreLocation
import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

@MainActor
struct DataLocatorTests {
    @Test func scanFindsOnlyExistingArchives() throws {
        let dir = URL.temporaryDirectory.appending(path: "izzy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appending(path: "tasveg.pmtiles"))

        let location = DataLocator.scan(directory: dir)
        #expect(location.url(for: .tasveg)?.lastPathComponent == "tasveg.pmtiles")
        #expect(location.url(for: .topo) == nil)
        #expect(!location.isEmpty)
    }

    @Test func noDirectoryMeansNoData() {
        #expect(DataLocator.locate(debugDirectory: nil) == .none)
        #expect(DataLocator.locate(debugDirectory: "") == .none)
    }

    @Test func aMissingDirectoryYieldsNoArchives() {
        let location = DataLocator.locate(debugDirectory: "/nonexistent/dir")
        #expect(location.origin == .debugDirectory(URL(filePath: "/nonexistent/dir", directoryHint: .isDirectory)))
        #expect(location.isEmpty)
    }
}

@MainActor
struct CommunityNameTests {
    @Test func codePrefixIsStripped() {
        #expect(Community.stripCodePrefix("(DOB) Eucalyptus obliqua dry forest") == "Eucalyptus obliqua dry forest")
        #expect(Community.stripCodePrefix("Something else") == "Something else")
    }

    @Test func selectingUsesTheTable() throws {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.selectCommunity(code: "DOB", sourceName: "ignored", attributes: ["FOREST_STR": "Tall forest", "WEED_TYP_D": "null"])
        guard case let .community(dob) = try #require(model.selection).feature else { Issue.record("not a community"); return }
        #expect(dob.name == "Eucalyptus obliqua dry forest")
        #expect(dob.colorHex == "#38a800")
        #expect(dob.structure == "Tall forest")
        #expect(dob.weeds == nil)  // the tiles' "null" string is no fact
        model.selectCommunity(code: "ZZZ", sourceName: "(ZZZ) Unknown community")
        guard case let .community(zzz) = try #require(model.selection).feature else { Issue.record("not a community"); return }
        #expect(zzz.name == "Unknown community")
        #expect(zzz.colorHex == nil)
    }
}

@MainActor
struct CameraPolicyTests {
    @Test func savedCameraOutsideTasmaniaFallsBackToStatewide() {
        #expect(CameraPolicy.initial(saved: nil) == CameraPolicy.home)
        let sydney = SavedCamera(latitude: -33.87, longitude: 151.21, zoom: 12)
        #expect(CameraPolicy.initial(saved: sydney) == CameraPolicy.home)
        let hobart = SavedCamera(latitude: -42.88, longitude: 147.33, zoom: 25)
        #expect(CameraPolicy.initial(saved: hobart).zoom == CameraPolicy.maxZoom)
        let broken = SavedCamera(latitude: -42.88, longitude: 147.33, zoom: .nan)
        #expect(CameraPolicy.initial(saved: broken) == CameraPolicy.home)
    }

    @Test func cameraRoundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "izzy-test-\(UUID().uuidString)"))
        let store = CameraStore(defaults: defaults)
        #expect(store.load() == nil)
        let camera = SavedCamera(latitude: -41.44, longitude: 147.14, zoom: 11.5, heading: 30)
        store.save(camera)
        #expect(store.load() == camera)
    }
}

/// A clock the test moves by hand; sleepers resume when it passes their deadline.
@MainActor
final class ManualClock {
    private(set) var now = ContinuousClock.now
    private var sleepers: [(id: UUID, deadline: ContinuousClock.Instant, wake: CheckedContinuation<Void, any Error>)] = []

    var clock: LocationClock {
        // strong: a model's tasks may outlive the test that made the clock
        LocationClock(now: { self.now }, sleep: { try await self.sleep($0) })
    }

    var sleeperCount: Int { sleepers.count }

    func sleep(_ duration: Duration) async throws {
        let id = UUID(), deadline = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { sleepers.append((id, deadline, $0)) }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func advance(by duration: Duration) {
        now += duration
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due { sleeper.wake.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: i).wake.resume(throwing: CancellationError())
    }
}

/// Lets the model's tasks run until `condition` holds (bounded).
@MainActor
func settle(_ condition: () -> Bool = { false }) async {
    for _ in 0 ..< 200 {
        if condition() { return }
        await Task.yield()
    }
}

@MainActor
struct LocationRulesTests {
    private func following(_ clock: ManualClock) async -> AppModel {
        let model = AppModel(data: .none, tables: .empty, clock: clock.clock)
        model.authorization = .authorizedWhenInUse
        model.cycleTracking()
        await settle { clock.sleeperCount > 0 }
        return model
    }

    @Test func trackingCyclesOffFollowHeading() {
        let model = AppModel(data: .none, tables: .empty)
        model.authorization = .authorizedWhenInUse
        model.cycleTracking(); #expect(model.trackingMode == .follow)
        model.cycleTracking(); #expect(model.trackingMode == .followWithHeading)
        model.cycleTracking(); #expect(model.trackingMode == .off)
    }

    @Test func deniedNeverStartsFollowingAndSaysWhy() {
        let model = AppModel(data: .none, tables: .empty)
        model.authorization = .denied
        model.cycleTracking()
        #expect(model.trackingMode == .off)
        #expect(model.notice == .denied)
    }

    /// The real path: MapLibre never reports "no fix", so the watch must.
    @Test func noFixAtAllSpeaksAfterTheDelayAndKeepsFollowing() async {
        let clock = ManualClock()
        let model = await following(clock)
        clock.advance(by: AppModel.noFixDelay - .seconds(1))
        await settle()
        #expect(model.notice == nil)
        clock.advance(by: .seconds(1))
        await settle { model.notice != nil }
        #expect(model.notice == .noFix)
        #expect(model.trackingMode == .follow)
        // and the message goes away by itself
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.noticeDuration)
        await settle { model.notice == nil }
        #expect(model.notice == nil)
    }

    @Test func aFixDuringTheDelayMeansNoMessage() async {
        let clock = ManualClock()
        let model = await following(clock)
        clock.advance(by: .seconds(3))
        model.locationUpdated()
        clock.advance(by: .seconds(30))
        await settle()
        #expect(model.notice == nil)
    }

    /// The puck from before following still shows a recent fix: no message
    /// while it is recent; once it is stale and nothing new came, say so.
    @Test func aRecentFixFromBeforeFollowingDefersTheMessage() async {
        let clock = ManualClock()
        let model = AppModel(data: .none, tables: .empty, clock: clock.clock)
        model.authorization = .authorizedWhenInUse
        model.locationUpdated()
        clock.advance(by: .seconds(30))
        model.cycleTracking()
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.noFixDelay)  // fix is 40 s old
        await settle()
        #expect(model.notice == nil)
        clock.advance(by: .seconds(19))          // 59 s
        await settle()
        #expect(model.notice == nil)
        clock.advance(by: .seconds(1))           // 60 s: stale
        await settle { model.notice != nil }
        #expect(model.notice == .noFix)
    }

    @Test func aStaleFixFromBeforeFollowingDoesNotCount() async {
        let clock = ManualClock()
        let model = AppModel(data: .none, tables: .empty, clock: clock.clock)
        model.authorization = .authorizedWhenInUse
        model.locationUpdated()
        clock.advance(by: .seconds(90))
        model.cycleTracking()
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.noFixDelay)
        await settle { model.notice != nil }
        #expect(model.notice == .noFix)
    }

    @Test func aFixDismissesTheMessageAndItSpeaksOncePerSession() async {
        let clock = ManualClock()
        let model = await following(clock)
        clock.advance(by: AppModel.noFixDelay)
        await settle { model.notice != nil }
        #expect(model.notice == .noFix)
        model.locationUpdated()
        #expect(model.notice == nil)
        // off and on again, no fix: no second message
        model.cycleTracking(); model.cycleTracking()   // heading, off
        clock.advance(by: .seconds(120))
        model.cycleTracking()                          // follow
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(120))
        await settle()
        #expect(model.notice == nil)
    }

    @Test func stoppingFollowingCancelsTheWatch() async {
        let clock = ManualClock()
        let model = await following(clock)
        model.mapChangedTracking(to: .off)   // a pan ends following
        clock.advance(by: .seconds(60))
        await settle()
        #expect(model.notice == nil)
    }

    @Test func followingStartsOnceThePromptIsAnsweredYes() {
        let model = AppModel(data: .none, tables: .empty)
        model.cycleTracking()                       // prompt shows
        model.mapChangedTracking(to: .off)          // the map drops it meanwhile
        model.authorizationChanged(to: .authorizedWhenInUse)
        #expect(model.trackingMode == .follow)
        #expect(model.notice == nil)
    }

    @Test func answeringNoToThePromptSaysWhy() {
        let model = AppModel(data: .none, tables: .empty)
        model.cycleTracking()
        model.mapChangedTracking(to: .off)
        model.authorizationChanged(to: .denied)
        #expect(model.trackingMode == .off)
        #expect(model.notice == .denied)
    }

    @Test func revokingPermissionEndsFollowing() {
        let model = AppModel(data: .none, tables: .empty)
        model.authorization = .authorizedWhenInUse
        model.cycleTracking()
        model.authorizationChanged(to: .denied)
        #expect(model.trackingMode == .off)
        #expect(model.notice == .denied)
    }

    @Test func aDenialFromTheMapEndsFollowing() {
        let model = AppModel(data: .none, tables: .empty)
        model.authorization = .authorizedWhenInUse
        model.cycleTracking()
        model.locationDenied()
        #expect(model.trackingMode == .off)
        #expect(model.notice == .denied)
    }
}

@MainActor
struct IdleTimerTests {
    @Test func screenStaysOnWhileAnyForegroundWindowFollows() {
        var writes: [Bool] = []
        let idle = IdleTimerCoordinator { writes.append($0) }
        let a = UUID(), b = UUID()
        idle.update(window: a, keepsAwake: false)
        #expect(writes == [false])
        idle.update(window: a, keepsAwake: true)
        idle.update(window: b, keepsAwake: true)
        #expect(writes == [false, true])           // no redundant writes
        idle.update(window: a, keepsAwake: false)  // a stops; b still follows
        #expect(idle.isIdleTimerDisabled)
        idle.remove(window: b)                     // b's window closed
        #expect(writes == [false, true, false])
        #expect(!idle.isIdleTimerDisabled)
        idle.remove(window: b)                     // twice is harmless
        #expect(writes.count == 3)
    }

    @Test func onlyFollowingInTheForegroundKeepsAwake() {
        #expect(IdleTimerCoordinator.keepsAwake(following: true, foreground: true))
        #expect(!IdleTimerCoordinator.keepsAwake(following: true, foreground: false))
        #expect(!IdleTimerCoordinator.keepsAwake(following: false, foreground: true))
    }

    /// A follower going to the background lets the screen sleep even though
    /// another, foreground window is open but not following.
    @Test func backgroundFollowerDoesNotKeepTheScreenOn() {
        var last: Bool?
        let idle = IdleTimerCoordinator { last = $0 }
        let follower = UUID(), other = UUID()
        idle.update(window: follower, keepsAwake: IdleTimerCoordinator.keepsAwake(following: true, foreground: true))
        idle.update(window: other, keepsAwake: IdleTimerCoordinator.keepsAwake(following: false, foreground: true))
        #expect(last == true)
        idle.update(window: follower, keepsAwake: IdleTimerCoordinator.keepsAwake(following: true, foreground: false))
        #expect(last == false)
    }
}

@MainActor
struct WindowModelTests {
    @Test func windowsShareTheLoadedDataButNotTheirState() {
        let shared = AppData(location: .none, tables: StyleBuilderTests.tables)
        let a = AppModel(shared: shared), b = AppModel(shared: shared)
        a.selectCommunity(code: "DOB", sourceName: nil)
        a.authorization = .authorizedWhenInUse
        a.cycleTracking()
        #expect(b.selection == nil)
        #expect(b.trackingMode == .off)
        #expect(a.styleJSON(selection: .none) == b.styleJSON(selection: .none))
        #expect(a.map !== b.map)
    }

    @Test func escapeWalksBackOneLevel() {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        #expect(model.escapeStep == nil)
        model.selectCommunity(code: "DOB", sourceName: nil)
        #expect(model.escapeStep == .closeCard)
        model.present(.layers)
        #expect(model.escapeStep == .dismiss(.layers))
        #expect(model.escapeStep?.title == "Close Layers")
        model.escape()
        #expect(model.modal == nil)
        #expect(model.selection != nil)
        model.escape()
        #expect(model.selection == nil)
        #expect(model.escapeStep == nil)
        model.escape()  // nothing left: no-op
        #expect(model.escapeStep == nil)
    }

    @Test func escapeClosesThePhotoViewerFirst() {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.selectCommunity(code: "DOB", sourceName: nil)
        model.photoViewer = UUID()
        #expect(model.escapeStep == .closePhoto)
        #expect(model.escapeStep?.title == "Close Photo")
        model.escape()
        #expect(model.photoViewer == nil)
        #expect(model.selection != nil)
        // the sheet that opened it going away closes it too
        model.photoViewer = UUID()
        model.present(.layers)
        #expect(model.photoViewer == nil)
    }

    @Test func aLayoutSwitchResetsTheModal() {
        let model = AppModel(data: .none, tables: .empty)
        model.layoutChanged(to: .sheet)
        model.present(.plantID)
        #expect(model.isPresenting(.plantID, in: .sheet))
        #expect(!model.isPresenting(.plantID, in: .card))
        model.layoutChanged(to: .card)
        #expect(model.modal == nil)
        model.present(.layers)
        #expect(model.modal == ModalRequest(presentation: .layers, layout: .card))
        model.layoutChanged(to: .card)  // same layout: kept
        #expect(model.modal != nil)
    }
}

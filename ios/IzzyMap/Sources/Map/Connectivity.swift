import Foundation
import MapLibre
import Network
import Observation

/// Whether the device has a usable network path (`NWPathMonitor`), for the
/// two things that stream: the live LIST map sources and thumbnails of
/// packs that aren't on the device.
///
/// Offline the style leaves the live sources out entirely: the packs, which
/// MapLibre stretches natively above z15, are then the whole map — no
/// failing requests, no retries on every camera move, no holes. Online the
/// live sources come back above the packs. A path that is "satisfied" but
/// can't reach LIST (one bar in the bush) costs only failed live tiles: the
/// pack still draws underneath, so the map never shows holes either way.
///
/// Starts offline until the first path update (a few ms after launch), so
/// a launch in airplane mode never requests anything.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var online = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var handlers: [UUID: @MainActor (Bool) -> Void] = [:]

    private init() {
        #if DEBUG
        // `-simulateOffline YES`: the path never comes up (screenshots, tests)
        if UserDefaults.standard.bool(forKey: "simulateOffline") {
            Self.failEveryRequest()
            return
        }
        // `-failRequests YES`: "online" but nothing gets through (weak signal)
        if UserDefaults.standard.bool(forKey: "failRequests") { Self.failEveryRequest() }
        #endif
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.update(up) }
        }
        monitor.start(queue: DispatchQueue(label: "org.gruenschloss.izzymap.path"))
    }

    /// Calls `handler` on every change (main actor). Keep the token alive;
    /// dropping it ends the subscription.
    func observe(_ handler: @escaping @MainActor (Bool) -> Void) -> Subscription {
        let id = UUID()
        handlers[id] = handler
        return Subscription { [weak self] in self?.handlers[id] = nil }
    }

    private func update(_ up: Bool) {
        guard up != online else { return }
        online = up
        for handler in handlers.values { handler(up) }
    }

    final class Subscription {
        private let cancel: @MainActor () -> Void
        init(_ cancel: @escaping @MainActor () -> Void) { self.cancel = cancel }
        isolated deinit { cancel() }
    }

    #if DEBUG
    /// Every http(s) request MapLibre makes fails as "not connected" — the
    /// map proof's offline simulation, through MapLibre's supported session
    /// configuration hook.
    private static func failEveryRequest() {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [FailingURLProtocol.self]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
    }
    #endif
}

#if DEBUG
/// DEBUG only: fails every http(s) request (offline simulation).
nonisolated final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        let scheme = request.url?.scheme ?? ""
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif

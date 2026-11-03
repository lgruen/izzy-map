import Foundation
import IzzyKit
import UIKit

/// One tile request's answer, as the downloader's rules see it.
nonisolated enum AreaFetch: Sendable, Equatable {
    /// HTTP 200 with a body (checked for an image by the downloader).
    case body(Data)
    /// HTTP 404: LIST has no tile here.
    case absent
    /// Another status, or a transfer error worth another try.
    case failed(String)
    /// No network path at all: retrying now is pointless.
    case offline
    case cancelled
}

/// How area tiles travel. The app uses `LiveAreaTransport`; tests fake it.
nonisolated protocol AreaTransport: Sendable {
    /// One attempt (the downloader retries).
    func fetch(_ url: URL) async -> AreaFetch
}

/// LIST over an ordinary ephemeral session: no URL cache (the area archive
/// is the cache), no waiting for connectivity (no reception answers at
/// once — the download stops, resumable). A `BGContinuedProcessingTask`
/// keeps the process running in the background, so this foreground session
/// carries on there too; no background session is needed.
nonisolated final class LiveAreaTransport: AreaTransport {
    static let shared = LiveAreaTransport()

    /// Idle limit per request: no bytes for this long is a stall.
    static let timeout: TimeInterval = 30

    private let session: URLSession

    init() {
        let config = ExtrasNetwork.configuration(timeout: Self.timeout, resourceTimeout: 120)
        // six requests in flight to one host (AreaPlan.concurrency)
        config.httpMaximumConnectionsPerHost = AreaPlan.concurrency
        config.httpAdditionalHeaders = ["Accept": "image/png, image/jpeg, image/*;q=0.8"]
        session = URLSession(configuration: config)
    }

    func fetch(_ url: URL) async -> AreaFetch {
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // LIST answers on its own host only: a redirect elsewhere (a
            // captive portal's usual move) is not a tile
            guard response.url?.host() == url.host() else { return .failed("redirected off theLIST") }
            switch status {
            case 200: return .body(data)
            case 404: return .absent
            default: return .failed("HTTP \(status)")
            }
        } catch {
            return Self.answer(to: error)
        }
    }

    /// A transfer error as the downloader's rules see it. Only "not
    /// connected" is `offline`; a host that can't be found or reached (DNS
    /// or a Wi-Fi hand-over) is a failure like any other — both are tried
    /// again for ~30 s before the layer stops.
    static func answer(to error: any Error) -> AreaFetch {
        if error is CancellationError { return .cancelled }
        guard let url = error as? URLError else { return .failed("transfer failed") }
        switch url.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .cannotFindHost, .dnsLookupFailed: return .failed("theLIST not found")
        case .cannotConnectToHost: return .failed("theLIST not reachable")
        case .timedOut: return .failed("timed out")
        case .networkConnectionLost: return .failed("connection dropped")
        default: return .failed("\(url.code.rawValue)")
        }
    }
}

#if DEBUG
/// DEBUG `-fakeAreaTransport <mode>` (UI tests, screenshots): area tiles
/// answer from memory — a small generated JPEG — after `-fakeAreaDelay`
/// milliseconds (default 15). `missing`: every z ≥ 16 tile is a 404.
nonisolated final class FakeAreaTransport: AreaTransport {
    static let key = "fakeAreaTransport"
    static var isOn: Bool { UserDefaults.standard.string(forKey: key) != nil }

    let delay: Duration
    let missing: Bool
    /// A grey 256 px JPEG (made once, on the main thread at first use).
    let tile: Data

    init(delay: Duration, missing: Bool, tile: Data) {
        self.delay = delay
        self.missing = missing
        self.tile = tile
    }

    @MainActor static func fromLaunchArguments() -> FakeAreaTransport {
        let ms = UserDefaults.standard.integer(forKey: "fakeAreaDelay")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            return f
        }())
        let image = renderer.image { ctx in
            UIColor(white: 0.55, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        return FakeAreaTransport(delay: .milliseconds(ms > 0 ? ms : 15),
                                 missing: UserDefaults.standard.string(forKey: key) == "missing",
                                 tile: image.jpegData(compressionQuality: 0.5) ?? Data([0xFF, 0xD8, 0xFF]))
    }

    func fetch(_ url: URL) async -> AreaFetch {
        do { try await Task.sleep(for: delay) } catch { return .cancelled }
        // …/tile/{z}/{y}/{x}
        let z = Int(url.pathComponents.dropLast(2).last ?? "") ?? 0
        if missing, z >= 16 { return .absent }
        return .body(tile)
    }
}
#endif

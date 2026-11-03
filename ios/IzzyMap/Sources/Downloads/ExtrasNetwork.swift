import Foundation
import IzzyKit
import PDFKit
import UIKit

/// Single-file fetches straight from the publisher (no relay: native apps
/// have no CORS). Used for a tapped document and for photos shown on
/// screen; the one-tap batches go through `ExtrasTransport`.
nonisolated enum ExtrasNetwork {
    /// Whole-transfer ceiling: a 6.6 MB chapter at ~20 KB/s still arrives.
    static let resourceTimeout: TimeInterval = 600

    /// A fresh ephemeral session: no URL cache (the store is the cache),
    /// no waiting for connectivity (offline must answer at once).
    /// `timeout` is the IDLE limit — no bytes for that long is a stall —
    /// not a cap on the whole download (`resourceTimeout`).
    static func session(timeout: TimeInterval, resourceTimeout: TimeInterval = ExtrasNetwork.resourceTimeout) -> URLSession {
        URLSession(configuration: configuration(timeout: timeout, resourceTimeout: resourceTimeout))
    }

    static func configuration(timeout: TimeInterval, resourceTimeout: TimeInterval = ExtrasNetwork.resourceTimeout)
        -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, resourceTimeout)
        config.httpMaximumConnectionsPerHost = 4
        #if DEBUG
        // the stub answers first; simulated offline, whatever it doesn't fails
        var debugClasses: [AnyClass] = []
        if let stub = StubNetwork.current { debugClasses.append(stub) }
        if DebugNetwork.simulatedOffline { debugClasses.append(FailingURLProtocol.self) }
        config.protocolClasses = debugClasses + (config.protocolClasses ?? [])
        #endif
        return config
    }

    /// Fetches `url` into a temporary file (the caller moves or deletes it).
    /// Redirects are followed only while they stay on the kind's hosts; a
    /// refused redirect (a captive portal's usual move) never stores anything.
    static func fetch(_ url: URL, kind: ExtraKind, session: URLSession) async -> (FetchResult, URL?) {
        do {
            let (file, response) = try await session.download(for: URLRequest(url: url), delegate: RedirectGuard(kind: kind))
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (300 ..< 400).contains(status) {
                try? FileManager.default.removeItem(at: file)
                return (.response(status: 200, head: Data(), allowedHost: false), nil)
            }
            let allowed = ExtrasCatalog.allows(host: response.url?.host(), for: kind)
            return checked(.response(status: status, head: fileHead(file), allowedHost: allowed), file: file, kind: kind)
        } catch {
            return (result(of: error), nil)
        }
    }

    /// A body that passes the magic check must also OPEN: a truncated or
    /// corrupt PDF ("%PDF" and then garbage) would otherwise be kept for
    /// ever. It counts as a failed transfer — retried, never stored.
    static func checked(_ result: FetchResult, file: URL, kind: ExtraKind) -> (FetchResult, URL?) {
        guard case let .response(status, head, allowed) = result, (200 ..< 300).contains(status), allowed,
              kind.expected == .pdf, ContentSniff.isPDF(head) else { return (result, file) }
        if DocumentCheck.opens(file) { return (result, file) }
        try? FileManager.default.removeItem(at: file)
        return (.failed, nil)
    }

    /// A transport error as the rules see it.
    static func result(of error: any Error) -> FetchResult {
        if error is CancellationError { return .cancelled }
        guard let e = error as? URLError else { return .failed }
        switch e.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        // a connection dropped mid-transfer (Wi-Fi → cellular): one failed
        // transfer, retried — if the network is really gone, the retry says so
        case .networkConnectionLost: return .failed
        default: return .failed
        }
    }
}

/// Whether a stored or downloaded PDF opens: PDFKit parses it and finds
/// at least one page. Safe off the main thread.
nonisolated enum DocumentCheck {
    static func opens(_ url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        return document.pageCount > 0
    }
}

/// Follows a redirect only onto the kind's allowed hosts.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let kind: ExtraKind
    init(kind: ExtraKind) { self.kind = kind }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(ExtrasCatalog.allows(host: request.url?.host(), for: kind) ? request : nil)
    }
}

#if DEBUG
/// DEBUG launch argument `-stubNetwork <mode>` (UI tests, screenshots):
/// - `documents`: F2F chapters and tree sheets answer with a small
///   generated PDF; everything else goes to the network;
/// - `gone`: tree sheets answer HTTP 400 + HTML (ArcGIS's removed item);
/// - `portal`: documents answer 200 HTML (a Wi-Fi login page);
/// - `offline`: every extras request fails as not connected;
/// - `broken`: documents answer "%PDF" followed by garbage (a corrupt file).
nonisolated enum StubNetwork {
    static var current: AnyClass? {
        UserDefaults.standard.string(forKey: "stubNetwork") == nil ? nil : StubURLProtocol.self
    }
    static var mode: String { UserDefaults.standard.string(forKey: "stubNetwork") ?? "" }

    /// A 12-page PDF, each page saying which it is.
    static let pdf: Data = {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            for n in 1 ... 12 {
                ctx.beginPage()
                let text = "Stub document — page \(n)" as NSString
                text.draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
            }
        }
    }()
}

nonisolated final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        if StubNetwork.mode == "offline" { return true }
        return host == "www.arcgis.com" || host == "nre.tas.gov.au"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let mode = StubNetwork.mode
        if mode == "offline" {
            client.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body, type): (Int, Data, String) = switch mode {
        case "gone" where url.host() == "www.arcgis.com": (400, Data("<html>Item does not exist</html>".utf8), "text/html")
        case "portal": (200, Data("<html><title>Log in to Wi-Fi</title></html>".utf8), "text/html")
        case "broken": (200, Data("%PDF-1.7\n% truncated".utf8), "application/pdf")
        default: (200, StubNetwork.pdf, "application/pdf")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(body.count)"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif

import Foundation
import Observation
import UIKit

/// Google, for the export sheet: the account link, the uploader, and the
/// last Doc made per project this session. One per app (`shared`); nil
/// when the build has no OAuth client id — then the sheet offers only the
/// file. DEBUG `-googleStub YES` swaps in a scripted Google (UI tests,
/// screenshots): no network, no credentials, a stub sign-in page.
@MainActor
@Observable
final class GoogleDrive {
    let auth: GoogleAuth
    @ObservationIgnored let transport: any HTTPTransport
    /// The consent page; the sheet passes the SwiftUI one, a stub run
    /// replaces it.
    @ObservationIgnored private let authenticatorOverride: WebAuthenticator?
    /// The last Doc made, per project key (`PinExportTarget.projectKey`).
    var lastLinks: [String: DriveFile] = [:]
    @ObservationIgnored var uploaderTuning: (DriveUploader) -> DriveUploader = { $0 }

    init(auth: GoogleAuth, transport: any HTTPTransport, authenticator: WebAuthenticator? = nil) {
        self.auth = auth
        self.transport = transport
        authenticatorOverride = authenticator
    }

    static let shared: GoogleDrive? = make()

    private static func make() -> GoogleDrive? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "googleStub") { return GoogleStub.drive() }
        #endif
        guard let config = GoogleOAuthConfig.fromBundle() else { return nil }
        GoogleInstallCheck.run()
        let transport = LoggingTransport(base: URLSessionTransport())
        return GoogleDrive(auth: GoogleAuth(config: config, transport: transport, store: KeychainTokenStore()), transport: transport)
    }

    var isConnected: Bool { auth.isConnected }

    func signIn(using authenticate: @escaping WebAuthenticator) async throws {
        try await auth.signIn(using: authenticatorOverride ?? authenticate)
    }

    func disconnect() async { await auth.disconnect() }

    /// Uploads as a new Doc. A refused refresh token surfaces as
    /// `DriveUploadError.signedOut`.
    func upload(_ data: Data, name: String, progress: @escaping @Sendable (Double) async -> Void) async throws -> DriveFile {
        let auth = self.auth
        let uploader = uploaderTuning(DriveUploader(transport: transport, token: { force in
            try await auth.accessToken(forceRefresh: force)
        }))
        return try await uploader.upload(data, name: name, progress: progress)
    }
}

/// The Keychain outlives the app: a token left by an earlier install
/// would make a fresh one say "Connected to Google Drive" without her
/// signing in — and docs/PRIVACY.md promises that removing the app removes
/// what it stored. So the first run of an install (no marker in
/// UserDefaults, which a reinstall empties but an update keeps) deletes
/// the stored Google token and sets the marker. Only while protected data
/// is readable: before the first unlock (a prewarmed launch) UserDefaults
/// can read as empty, and that must not count as a fresh install.
enum GoogleInstallCheck {
    static let key = "pinsExportGoogleInstallMarker"

    /// Whether it deleted (a fresh install).
    @discardableResult
    static func run(defaults: UserDefaults = .standard, store: any TokenStore = KeychainTokenStore(),
                    protectedDataAvailable: Bool = UIApplication.shared.isProtectedDataAvailable) -> Bool {
        guard protectedDataAvailable, !defaults.bool(forKey: key) else { return false }
        store.delete()
        defaults.set(true, forKey: key)
        return true
    }
}

#if DEBUG
/// A scripted Google for UI tests and screenshots (`-googleStub YES`):
/// the sign-in page answers at once with a code for the right `state`; the
/// token endpoint, the upload session and the chunks answer like Drive.
/// `-googleStubDelay <seconds>` slows each exchange (progress screenshots);
/// `-googleStubFail offline|full|convert|signedOut` makes the upload fail
/// that way; `-googleStubConnected YES` starts signed in.
enum GoogleStub {
    static let config = GoogleOAuthConfig(clientID: "000000000000-stub.apps.googleusercontent.com")!

    static func drive() -> GoogleDrive {
        let args = UserDefaults.standard
        let transport = LoggingTransport(base: Transport(delay: args.double(forKey: "googleStubDelay"),
                                                         failure: args.string(forKey: "googleStubFail")))
        let store = MemoryTokenStore(args.bool(forKey: "googleStubConnected") ? "stub-refresh" : nil)
        let drive = GoogleDrive(auth: GoogleAuth(config: config, transport: transport, store: store), transport: transport) { url, scheme in
            try await Task.sleep(for: .milliseconds(300))
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=stub-code&scope=\(GoogleOAuthConfig.scope)")!
        }
        // small chunks so the stub's progress moves
        drive.uploaderTuning = { var u = $0; u.chunkSize = 256 * 1024; u.sleep = { _ in }; return u }
        return drive
    }

    struct Transport: HTTPTransport {
        let delay: Double
        let failure: String?

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            let url = request.url!
            func reply(_ status: Int, _ json: String = "{}", headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
                (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            }
            switch (request.httpMethod ?? "GET", url.host() ?? "", url.path()) {
            case ("POST", "oauth2.googleapis.com", "/token"):
                if failure == "signedOut" { return reply(400, #"{"error":"invalid_grant"}"#) }
                return reply(200, #"{"access_token":"stub-access","expires_in":3599,"refresh_token":"stub-refresh","scope":"\#(GoogleOAuthConfig.scope)","token_type":"Bearer"}"#)
            case ("POST", "oauth2.googleapis.com", "/revoke"):
                return reply(200)
            case ("POST", _, "/upload/drive/v3/files"):
                switch failure {
                case "offline": throw URLError(.notConnectedToInternet)
                case "full": return reply(403, #"{"error":{"code":403,"message":"The user's Drive storage quota has been exceeded.","errors":[{"reason":"storageQuotaExceeded"}]}}"#)
                default: return reply(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=stub"])
                }
            case ("PUT", _, "/upload/drive/v3/files"):
                let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
                // "bytes a-b/total" (or "bytes */total")
                let parts = range.dropFirst("bytes ".count).split(separator: "/")
                let total = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
                let end = parts.first?.split(separator: "-").last.flatMap { Int($0) } ?? -1
                if end + 1 < total { return reply(308, headers: ["Range": "bytes=0-\(end)"]) }
                if failure == "convert" { return reply(400, #"{"error":{"code":400,"message":"Unable to convert the file to a Google Docs document.","errors":[{"reason":"badRequest"}]}}"#) }
                return reply(200, #"{"id":"stub-doc","webViewLink":"https://docs.google.com/document/d/stub-doc/edit"}"#)
            default:
                return reply(404)
            }
        }
    }
}
#endif

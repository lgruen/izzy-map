import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import os
import Security

// Signing in to Google for the export (docs/PINS_PLAN.md §6), without any
// SDK: OAuth 2.0 for an installed app — authorization code + PKCE (RFC
// 7636, S256) in ASWebAuthenticationSession (her browser session, not an
// ephemeral one), the iOS client's reversed client id as the redirect, no
// client secret. One scope, `drive.file`: the app sees only files it made.
// The refresh token lives in the Keychain (this device only); access
// tokens in memory, refreshed on demand.

/// The OAuth client: the id from Info.plist (`GoogleOAuthClientID`, filled
/// from a gitignored xcconfig) and what follows from it.
nonisolated struct GoogleOAuthConfig: Sendable, Equatable {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let suffix = ".apps.googleusercontent.com"

    let clientID: String

    /// nil unless `clientID` looks like an iOS client id
    /// ("<number>-<hash>.apps.googleusercontent.com").
    init?(clientID: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(Self.suffix), id.count > Self.suffix.count,
              id.dropLast(Self.suffix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        self.clientID = id
    }

    /// From the app's Info.plist; nil when the build had no id (the
    /// setting expands to "" — then Google isn't offered).
    static func fromBundle(_ bundle: Bundle = .main) -> GoogleOAuthConfig? {
        (bundle.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String).flatMap(GoogleOAuthConfig.init(clientID:))
    }

    /// "com.googleusercontent.apps.<prefix>" — the reversed client id.
    var redirectScheme: String { "com.googleusercontent.apps." + clientID.dropLast(Self.suffix.count) }
    var redirectURI: String { redirectScheme + ":/oauth2redirect" }

    /// The consent page's URL.
    func authorizationURL(state: String, codeChallenge: String) -> URL {
        var c = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }
}

/// RFC 7636: a high-entropy verifier and its S256 challenge.
nonisolated enum PKCE {
    /// 32 random bytes, base64url: 43 characters of [A-Za-z0-9-_].
    static func verifier() -> String { randomToken() }

    /// BASE64URL(SHA256(ASCII(verifier))), no padding.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 bytes from the system's CSPRNG, base64url (also the `state`).
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Transport

/// One HTTP exchange (URLSession in the app; a stub in tests and in DEBUG
/// `-googleStub` runs — never the network in tests).
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession without cookies or a cache: tokens and documents stay out of
/// any on-disk cache.
nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Logs every exchange's method, host + path and status — never a query
/// (an upload session URL is a capability), a header or a body, so never a
/// token. Visible with `log stream --predicate 'category == "GoogleExport"'`
/// or in Console.app: what the developer pastes when a real run fails.
nonisolated struct LoggingTransport: HTTPTransport {
    let base: any HTTPTransport
    static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "GoogleExport")

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let what = "\(request.httpMethod ?? "GET") \(request.url?.host() ?? "?")\(request.url?.path() ?? "")"
        let range = request.value(forHTTPHeaderField: "Content-Range").map { " [\($0)]" } ?? ""
        do {
            let (data, response) = try await base.send(request)
            var reason = ""
            if response.statusCode >= 400, let body = GoogleErrorBody(data) {
                reason = " \(body.error ?? "")" + (body.reasons.isEmpty ? "" : " " + body.reasons.joined(separator: ","))
                // the token endpoint's error_description tells a verifier
                // or redirect mismatch apart (it never holds a token)
                if request.url?.host() == GoogleOAuthConfig.tokenEndpoint.host(), let message = body.message {
                    reason += " — " + message
                }
            }
            Self.logger.notice("\(what, privacy: .public)\(range, privacy: .public) → \(response.statusCode)\(reason, privacy: .public)")
            return (data, response)
        } catch {
            let code = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: type(of: error))
            Self.logger.notice("\(what, privacy: .public)\(range, privacy: .public) → \(code, privacy: .public)")
            throw error
        }
    }
}

/// The parts of a Google error body we act on: OAuth's `{"error":
/// "invalid_grant"}` and the APIs' `{"error": {"code", "message",
/// "errors": [{"reason"}], "status"}}`.
nonisolated struct GoogleErrorBody: Sendable, Equatable {
    /// OAuth error code, or the API error's `status` ("PERMISSION_DENIED").
    var error: String?
    var message: String?
    /// The API error's `errors[].reason` ("storageQuotaExceeded", "rateLimitExceeded").
    var reasons: [String]

    init?(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = json["error"] as? String {
            error = code
            message = json["error_description"] as? String
            reasons = []
        } else if let api = json["error"] as? [String: Any] {
            error = api["status"] as? String
            message = api["message"] as? String
            reasons = (api["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
            if let details = api["details"] as? [[String: Any]] {
                reasons += details.compactMap { $0["reason"] as? String }
            }
        } else {
            return nil
        }
    }
}

// MARK: - Token storage

/// Where the refresh token is kept (the Keychain in the app; memory in tests).
nonisolated protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String) throws
    func delete()
}

/// A generic-password item of this app, readable after the first unlock,
/// never leaving this device (no iCloud Keychain, no backup restore onto
/// another device).
nonisolated struct KeychainTokenStore: TokenStore {
    var service = "org.gruenschloss.izzymap.google-oauth"
    var account = "refresh-token"

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String) throws {
        delete()
        var q = query
        q[kSecValueData] = Data(token.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw GoogleAuthError.keychain(status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// In memory (tests, DEBUG `-googleStub`).
nonisolated final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { lock.withLock { token } }
    func write(_ token: String) throws { lock.withLock { self.token = token } }
    func delete() { lock.withLock { token = nil } }
}

// MARK: - The account

nonisolated enum GoogleAuthError: Error, Equatable {
    /// She closed the sign-in page or declined: no error is shown.
    case cancelled
    /// The sign-in page itself failed (no window to show it in, no
    /// connection…): said, with the file offered.
    case signInPageFailed
    /// The redirect's `state` isn't the one sent (or the redirect is malformed).
    case stateMismatch
    /// She unticked Drive access on the consent page.
    case scopeNotGranted
    /// The refresh token was revoked or expired (`invalid_grant`): sign in again.
    case signedOut
    /// The token endpoint answered something else.
    case tokenEndpoint(status: Int, error: String?)
    case keychain(OSStatus)
}

/// Opens the consent page and returns the redirect URL (the SwiftUI
/// environment's `webAuthenticationSession` in the app; a stub in tests).
typealias WebAuthenticator = @MainActor (_ url: URL, _ callbackScheme: String) async throws -> URL

/// The app's link to her Google account: connected (a refresh token is in
/// the store) or not; access tokens on demand.
@MainActor
@Observable
final class GoogleAuth {
    let config: GoogleOAuthConfig
    @ObservationIgnored let transport: any HTTPTransport
    @ObservationIgnored let store: any TokenStore
    @ObservationIgnored let now: () -> Date

    /// A refresh token is stored (or this session holds a working access token).
    private(set) var isConnected: Bool
    @ObservationIgnored private var access: (token: String, expires: Date)?
    /// One refresh at a time.
    @ObservationIgnored private var refreshing: Task<String, any Error>?

    init(config: GoogleOAuthConfig, transport: any HTTPTransport, store: any TokenStore, now: @escaping () -> Date = { Date() }) {
        self.config = config
        self.transport = transport
        self.store = store
        self.now = now
        isConnected = store.read() != nil
    }

    // MARK: Sign-in

    /// The whole sign-in: consent page → code → tokens (refresh token to
    /// the store). Throws `.cancelled` when she backs out.
    func signIn(using authenticate: WebAuthenticator) async throws {
        let verifier = PKCE.verifier()
        let state = PKCE.randomToken()
        let url = config.authorizationURL(state: state, codeChallenge: PKCE.challenge(for: verifier))
        let redirect: URL
        do {
            redirect = try await authenticate(url, config.redirectScheme)
        } catch let error as GoogleAuthError {
            throw error
        } catch {
            throw Self.pageError(error)
        }
        let code = try Self.code(from: redirect, expectedState: state, redirectScheme: config.redirectScheme)
        LoggingTransport.logger.notice("sign-in redirect received")
        try await exchange(code: code, verifier: verifier)
    }

    /// What a failed sign-in page means: she closed it (or the task was
    /// cancelled) — nothing to report; anything else is a real failure.
    nonisolated static func pageError(_ error: any Error) -> GoogleAuthError {
        let closed = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin || error is CancellationError
        let what = (error as NSError).domain + " " + String((error as NSError).code)
        LoggingTransport.logger.notice("sign-in page \(closed ? "closed" : "failed", privacy: .public): \(what, privacy: .public)")
        return closed ? .cancelled : .signInPageFailed
    }

    /// The authorization code from the redirect, after checking `state`.
    /// An `error` parameter (access_denied) counts as backing out.
    nonisolated static func code(from redirect: URL, expectedState: String, redirectScheme: String) throws -> String {
        guard redirect.scheme?.lowercased() == redirectScheme.lowercased(),
              let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems
        else { throw GoogleAuthError.stateMismatch }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw GoogleAuthError.stateMismatch }
        if value("error") != nil { throw GoogleAuthError.cancelled }
        guard let code = value("code"), !code.isEmpty else { throw GoogleAuthError.stateMismatch }
        return code
    }

    private func exchange(code: String, verifier: String) async throws {
        let response = try await tokenRequest([
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        // granular consent: Drive access may have been unticked
        guard response.scope?.split(separator: " ").contains(Substring(GoogleOAuthConfig.scope)) ?? true else {
            throw GoogleAuthError.scopeNotGranted
        }
        if let refresh = response.refreshToken { try store.write(refresh) }
        access = (response.accessToken, now().addingTimeInterval(response.expiresIn))
        isConnected = true
    }

    // MARK: Access tokens

    /// A valid access token: the cached one, else refreshed. `forceRefresh`
    /// after a 401. Throws `.signedOut` when the refresh token is refused
    /// (it is deleted then; the sheet asks to sign in again).
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let access, access.expires.timeIntervalSince(now()) > 60 { return access.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let refreshToken = store.read() else {
            access = nil
            isConnected = false
            throw GoogleAuthError.signedOut
        }
        do {
            let response = try await tokenRequest([
                "client_id": config.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ])
            access = (response.accessToken, now().addingTimeInterval(response.expiresIn))
            return response.accessToken
        } catch let GoogleAuthError.tokenEndpoint(status, error)
            where (400 ... 401).contains(status) && ["invalid_grant", "unauthorized_client", "invalid_client"].contains(error ?? "") {
            forget()
            throw GoogleAuthError.signedOut
        }
    }

    // MARK: Disconnect

    /// Revokes the grant at Google (best effort: offline it stays granted
    /// until she removes it in her account) and forgets the tokens.
    func disconnect() async {
        let token = store.read() ?? access?.token
        forget()
        guard let token else { return }
        var request = URLRequest(url: GoogleOAuthConfig.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": token])
        _ = try? await transport.send(request)
    }

    /// Deletes both tokens.
    func forget() {
        store.delete()
        access = nil
        isConnected = false
    }

    // MARK: Token endpoint

    nonisolated struct TokenResponse: Decodable, Sendable {
        var accessToken: String
        var expiresIn: TimeInterval
        var refreshToken: String?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token", scope
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: GoogleOAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GoogleAuthError.tokenEndpoint(status: response.statusCode, error: GoogleErrorBody(data)?.error)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleAuthError.tokenEndpoint(status: response.statusCode, error: "malformed")
        }
    }

    /// application/x-www-form-urlencoded, keys sorted (stable for tests).
    nonisolated static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

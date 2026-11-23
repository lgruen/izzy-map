import AuthenticationServices
import Foundation
import SwiftData
import Testing
@testable import IzzyMap

// Google sign-in and the Drive upload (docs/PINS_PLAN.md §6), against a
// scripted transport — never the network.

/// Answers each request with the next scripted reply (or a handler) and
/// records what was sent.
nonisolated final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case http(Int, String = "{}", headers: [String: String] = [:])
        case fail(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    /// When set, answers instead of the script.
    var handler: (@Sendable (URLRequest) throws -> Reply)?
    /// Each exchange takes this long (cancellable, like a real request).
    var delay: Duration?

    init(_ replies: [Reply] = []) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let delay { try await Task.sleep(for: delay) }
        let reply: Reply = try lock.withLock {
            requests.append(request)
            if let handler { return try handler(request) }
            guard !replies.isEmpty else { return .http(599, "{\"error\":\"unscripted\"}") }
            return replies.removeFirst()
        }
        switch reply {
        case let .http(status, body, headers):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        case let .fail(code):
            throw URLError(code)
        }
    }

    var sent: [URLRequest] { lock.withLock { requests } }
}

private func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var out: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        out[kv[0]] = kv.count > 1 ? kv[1] : ""
    }
    return out
}

private let config = GoogleOAuthConfig(clientID: "123456789012-abcdefghijklmnop.apps.googleusercontent.com")!

@Suite struct GoogleOAuthTests {
    /// RFC 7636, Appendix B.
    @Test func pkceChallengeMatchesTheRFCVector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifiersAreLongRandomAndURLSafe() {
        let a = PKCE.verifier(), b = PKCE.verifier()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func clientIDAndRedirect() {
        #expect(config.redirectScheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
        #expect(config.redirectURI == "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect")
        #expect(GoogleOAuthConfig(clientID: "") == nil)
        #expect(GoogleOAuthConfig(clientID: "$(GOOGLE_OAUTH_CLIENT_ID)") == nil)
        #expect(GoogleOAuthConfig(clientID: ".apps.googleusercontent.com") == nil)
        #expect(GoogleOAuthConfig(clientID: "x y.apps.googleusercontent.com") == nil)
    }

    @Test func authorizationURL() throws {
        let url = config.authorizationURL(state: "S1", codeChallenge: "C1")
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.scheme == "https" && c.host == "accounts.google.com" && c.path == "/o/oauth2/v2/auth")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q == [
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "response_type": "code",
            "scope": "https://www.googleapis.com/auth/drive.file",
            "code_challenge": "C1",
            "code_challenge_method": "S256",
            "state": "S1",
        ])
    }

    @Test func theRedirectsStateIsChecked() throws {
        let scheme = config.redirectScheme
        let ok = URL(string: "\(scheme):/oauth2redirect?state=abc&code=4/xyz&scope=https://www.googleapis.com/auth/drive.file")!
        #expect(try GoogleAuth.code(from: ok, expectedState: "abc", redirectScheme: scheme) == "4/xyz")
        #expect(throws: GoogleAuthError.stateMismatch) {
            try GoogleAuth.code(from: ok, expectedState: "other", redirectScheme: scheme)
        }
        #expect(throws: GoogleAuthError.stateMismatch) {
            try GoogleAuth.code(from: URL(string: "\(scheme):/oauth2redirect?code=4/xyz")!, expectedState: "abc", redirectScheme: scheme)
        }
        #expect(throws: GoogleAuthError.stateMismatch) {
            try GoogleAuth.code(from: URL(string: "evil:/oauth2redirect?state=abc&code=1")!, expectedState: "abc", redirectScheme: scheme)
        }
        #expect(throws: GoogleAuthError.cancelled) {
            try GoogleAuth.code(from: URL(string: "\(scheme):/oauth2redirect?state=abc&error=access_denied")!, expectedState: "abc", redirectScheme: scheme)
        }
    }
}

@MainActor
@Suite struct GoogleAuthTests {
    private let tokenOK = #"{"access_token":"A1","expires_in":3599,"refresh_token":"R1","scope":"https://www.googleapis.com/auth/drive.file","token_type":"Bearer"}"#

    /// The fake consent page: answers with the URL's own state and a code.
    private func consent(_ url: URL, _ scheme: String) -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=C0DE")!
    }

    @Test func signInExchangesTheCodeWithTheVerifierAndStoresTheRefreshToken() async throws {
        let transport = ScriptedTransport([.http(200, tokenOK)])
        let store = MemoryTokenStore()
        let auth = GoogleAuth(config: config, transport: transport, store: store)
        #expect(!auth.isConnected)
        var challenge = ""
        try await auth.signIn { url, scheme in
            #expect(scheme == config.redirectScheme)
            challenge = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "code_challenge" }!.value!
            return consent(url, scheme)
        }
        #expect(auth.isConnected)
        #expect(store.read() == "R1")
        let sent = try #require(transport.sent.first)
        #expect(sent.url == GoogleOAuthConfig.tokenEndpoint && sent.httpMethod == "POST")
        let f = form(sent)
        #expect(f["grant_type"] == "authorization_code" && f["code"] == "C0DE" && f["client_id"] == config.clientID)
        #expect(f["redirect_uri"] == config.redirectURI)
        #expect(f["client_secret"] == nil, "an iOS client has no secret")
        #expect(PKCE.challenge(for: try #require(f["code_verifier"])) == challenge, "the verifier matches the challenge sent")
        // the access token is cached: no second request
        #expect(try await auth.accessToken() == "A1")
        #expect(transport.sent.count == 1)
    }

    @Test func aClosedSignInPageIsACancelNotAnError() async {
        let auth = GoogleAuth(config: config, transport: ScriptedTransport(), store: MemoryTokenStore())
        await #expect(throws: GoogleAuthError.cancelled) {
            try await auth.signIn { _, _ in throw ASWebAuthenticationSessionError(.canceledLogin) }
        }
        #expect(!auth.isConnected)
    }

    /// Only her closing the page is silent; a page that couldn't show (no
    /// window, no connection) is a failure she is told about.
    @Test func aFailedSignInPageIsSaid() async {
        #expect(GoogleAuth.pageError(ASWebAuthenticationSessionError(.canceledLogin)) == .cancelled)
        #expect(GoogleAuth.pageError(CancellationError()) == .cancelled)
        #expect(GoogleAuth.pageError(ASWebAuthenticationSessionError(.presentationContextNotProvided)) == .signInPageFailed)
        #expect(GoogleAuth.pageError(ASWebAuthenticationSessionError(.presentationContextInvalid)) == .signInPageFailed)
        #expect(GoogleAuth.pageError(URLError(.notConnectedToInternet)) == .signInPageFailed)
        let auth = GoogleAuth(config: config, transport: ScriptedTransport(), store: MemoryTokenStore())
        await #expect(throws: GoogleAuthError.signInPageFailed) {
            try await auth.signIn { _, _ in throw ASWebAuthenticationSessionError(.presentationContextNotProvided) }
        }
        #expect(PinExportModel.failure(GoogleAuthError.signInPageFailed) == .signInFailed)
        #expect(PinExportFailure.signInFailed.title == "Couldn’t sign in to Google" && PinExportFailure.signInFailed.offersFile)
    }

    /// A token an earlier install left in the Keychain goes on an install's
    /// first run; never on a later run (an update keeps UserDefaults), never
    /// before the first unlock (UserDefaults may read as empty then).
    @Test func aFreshInstallForgetsAnOldInstallsToken() {
        let defaults = UserDefaults(suiteName: "izzymap-install-\(UUID().uuidString)")!
        let store = MemoryTokenStore("old-install")
        #expect(!GoogleInstallCheck.run(defaults: defaults, store: store, protectedDataAvailable: false))
        #expect(store.read() == "old-install", "locked device: nothing decided")
        #expect(GoogleInstallCheck.run(defaults: defaults, store: store, protectedDataAvailable: true))
        #expect(store.read() == nil)
        try? store.write("signed-in-since")
        #expect(!GoogleInstallCheck.run(defaults: defaults, store: store, protectedDataAvailable: true))
        #expect(store.read() == "signed-in-since", "a later launch (or an update) keeps it")
    }

    @Test func uncheckedDriveAccessIsRefused() async {
        let transport = ScriptedTransport([.http(200, #"{"access_token":"A1","expires_in":3599,"refresh_token":"R1","scope":"openid"}"#)])
        let store = MemoryTokenStore()
        let auth = GoogleAuth(config: config, transport: transport, store: store)
        await #expect(throws: GoogleAuthError.scopeNotGranted) { try await auth.signIn(using: consent) }
        #expect(store.read() == nil)
    }

    @Test func expiredAccessTokensAreRefreshedOnDemand() async throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let transport = ScriptedTransport([.http(200, #"{"access_token":"A2","expires_in":3599}"#),
                                           .http(200, #"{"access_token":"A3","expires_in":3599}"#),
                                           .http(200, #"{"access_token":"A4","expires_in":3599}"#)])
        let auth = GoogleAuth(config: config, transport: transport, store: MemoryTokenStore("R1"), now: { now })
        #expect(auth.isConnected, "a stored refresh token = connected")
        #expect(try await auth.accessToken() == "A2")
        let f = form(transport.sent[0])
        #expect(f["grant_type"] == "refresh_token" && f["refresh_token"] == "R1" && f["client_id"] == config.clientID)
        #expect(try await auth.accessToken() == "A2", "still valid")
        now = now.addingTimeInterval(3560)   // within a minute of expiry
        #expect(try await auth.accessToken() == "A3")
        #expect(try await auth.accessToken(forceRefresh: true) == "A4", "a forced refresh asks again")
    }

    @Test func invalidGrantSignsOut() async {
        let transport = ScriptedTransport([.http(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)])
        let store = MemoryTokenStore("R1")
        let auth = GoogleAuth(config: config, transport: transport, store: store)
        await #expect(throws: GoogleAuthError.signedOut) { try await auth.accessToken() }
        #expect(store.read() == nil, "the dead token is deleted")
        #expect(!auth.isConnected)
    }

    @Test func aServerErrorDuringRefreshKeepsTheToken() async {
        let store = MemoryTokenStore("R1")
        let auth = GoogleAuth(config: config, transport: ScriptedTransport([.http(503, "{}")]), store: store)
        await #expect(throws: GoogleAuthError.tokenEndpoint(status: 503, error: nil)) { try await auth.accessToken() }
        #expect(store.read() == "R1")
    }

    @Test func disconnectRevokesAndForgets() async throws {
        let transport = ScriptedTransport([.http(200, "")])
        let store = MemoryTokenStore("R1")
        let auth = GoogleAuth(config: config, transport: transport, store: store)
        await auth.disconnect()
        #expect(store.read() == nil && !auth.isConnected)
        let sent = try #require(transport.sent.first)
        #expect(sent.url == GoogleOAuthConfig.revokeEndpoint && form(sent)["token"] == "R1")
    }
}

@Suite struct DriveUploadTests {
    private let session = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=U1"
    private let done = #"{"id":"D1","webViewLink":"https://docs.google.com/document/d/D1/edit?usp=drivesdk"}"#

    private func uploader(_ t: ScriptedTransport, tokens: TokenLog = TokenLog()) -> DriveUploader {
        var u = DriveUploader(transport: t, token: { force in tokens.next(force) })
        u.chunkSize = 4
        u.sleep = { _ in }
        return u
    }

    nonisolated final class TokenLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var forced: [Bool] = []
        func next(_ force: Bool) -> String { lock.withLock { forced.append(force); return force ? "fresh" : "cached" } }
    }

    @Test func startsASessionThenSendsChunksUntilDone() async throws {
        let t = ScriptedTransport([
            .http(200, headers: ["Location": session]),
            .http(308, headers: ["Range": "bytes=0-3"]),
            .http(308, headers: ["Range": "bytes=0-7"]),
            .http(200, done),
        ])
        let file = try await uploader(t).upload(Data("0123456789".utf8), name: "Site — pins 2026-11-24")
        #expect(file == DriveFile(id: "D1", webViewLink: URL(string: "https://docs.google.com/document/d/D1/edit?usp=drivesdk")!))

        let start = t.sent[0]
        #expect(start.httpMethod == "POST")
        #expect(start.url?.absoluteString == "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")
        #expect(start.value(forHTTPHeaderField: "Authorization") == "Bearer cached")
        #expect(start.value(forHTTPHeaderField: "X-Upload-Content-Type") == DriveUploader.docxType)
        let meta = try #require(JSONSerialization.jsonObject(with: start.httpBody!) as? [String: String])
        #expect(meta == ["name": "Site — pins 2026-11-24", "mimeType": "application/vnd.google-apps.document"])

        #expect(t.sent[1...].map { $0.value(forHTTPHeaderField: "Content-Range") } == ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"])
        #expect(t.sent[1...].allSatisfy { $0.httpMethod == "PUT" && $0.url?.absoluteString == session })
        #expect(t.sent[3].httpBody == Data("89".utf8))
    }

    @Test func aDroppedConnectionAsksTheSessionAndResumes() async throws {
        let t = ScriptedTransport([
            .http(200, headers: ["Location": session]),
            .http(308, headers: ["Range": "bytes=0-3"]),
            .fail(.networkConnectionLost),          // the second chunk drops
            .fail(.notConnectedToInternet),         // still offline when asked
            .http(308, headers: ["Range": "bytes=0-5"]),   // it had 6 bytes
            .http(200, done),
        ])
        let file = try await uploader(t).upload(Data("0123456789".utf8), name: "x")
        #expect(file.id == "D1")
        let ranges = t.sent.compactMap { $0.value(forHTTPHeaderField: "Content-Range") }
        #expect(ranges == ["bytes 0-3/10", "bytes 4-7/10", "bytes */10", "bytes */10", "bytes 6-9/10"])
    }

    /// A link that kills every big PUT but lets the status query through
    /// must not loop forever: drops that move nothing are retries.
    @Test func dropsThatMoveNothingGiveUp() async {
        let t = ScriptedTransport()
        t.handler = { r in
            if r.httpMethod == "POST" { return .http(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=U"]) }
            if r.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes */") == true { return .http(308, headers: ["Range": "bytes=0-3"]) }
            return .fail(.networkConnectionLost)
        }
        await #expect(throws: DriveUploadError.offline) { try await uploader(t).upload(Data("0123456789".utf8), name: "x") }
        #expect(t.sent.count < 20)
    }

    /// Retries are per stall: a 503 on every one of five chunks (more
    /// than `retries` in all) still gets the upload through.
    @Test func retriesResetWhenTheUploadMovesOn() async throws {
        var script: [ScriptedTransport.Reply] = [.http(200, headers: ["Location": session])]
        for k in 0 ..< 5 {
            script.append(.http(503))
            script.append(k == 0 ? .http(308) : .http(308, headers: ["Range": "bytes=0-\(2 * k - 1)"]))
            script.append(k < 4 ? .http(308, headers: ["Range": "bytes=0-\(2 * k + 1)"]) : .http(200, done))
        }
        let t = ScriptedTransport(script)
        var u = uploader(t)
        u.chunkSize = 2
        #expect(try await u.upload(Data("0123456789".utf8), name: "x").id == "D1")
    }

    @Test func theLastChunkMayHaveArrivedBeforeTheDrop() async throws {
        let t = ScriptedTransport([
            .http(200, headers: ["Location": session]),
            .fail(.timedOut),
            .http(201, done),
        ])
        let u = { var u = uploader(t); u.chunkSize = 64; return u }()
        #expect(try await u.upload(Data("0123".utf8), name: "x").id == "D1")
    }

    @Test func offlineFromTheStartIsOffline() async {
        let t = ScriptedTransport()
        t.handler = { _ in .fail(.notConnectedToInternet) }
        await #expect(throws: DriveUploadError.offline) { try await uploader(t).upload(Data("0123".utf8), name: "x") }
        #expect(t.sent.count == 5, "first try + 4 retries")
    }

    @Test func a401RefreshesTheTokenOnceThenGivesUp() async throws {
        let tokens = TokenLog()
        let t = ScriptedTransport([.http(401), .http(200, headers: ["Location": session]), .http(200, done)])
        #expect(try await uploader(t, tokens: tokens).upload(Data("01".utf8), name: "x").id == "D1")
        #expect(tokens.forced == [false, true])
        #expect(t.sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")

        let t2 = ScriptedTransport([.http(401), .http(401)])
        await #expect(throws: DriveUploadError.unauthorized) { try await uploader(t2).upload(Data("01".utf8), name: "x") }
    }

    @Test func aRefusedRefreshTokenMeansSignInAgain() async {
        var u = DriveUploader(transport: ScriptedTransport(), token: { _ in throw GoogleAuthError.signedOut })
        u.sleep = { _ in }
        await #expect(throws: DriveUploadError.signedOut) { try await u.upload(Data("01".utf8), name: "x") }
    }

    @Test func aFullDriveIsSaidPlainly() async {
        let t = ScriptedTransport([.http(403, #"{"error":{"code":403,"message":"The user's Drive storage quota has been exceeded.","errors":[{"domain":"usageLimits","reason":"storageQuotaExceeded"}]}}"#)])
        await #expect(throws: DriveUploadError.driveFull) { try await uploader(t).upload(Data("01".utf8), name: "x") }
        #expect(t.sent.count == 1, "no retry")
    }

    @Test func rateLimitsAreRetriedWithBackoff() async throws {
        let waits = WaitLog()
        let t = ScriptedTransport([
            .http(429, #"{"error":{"code":429,"errors":[{"reason":"rateLimitExceeded"}]}}"#),
            .http(403, #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#),
            .http(200, headers: ["Location": session]),
            .http(200, done),
        ])
        var u = uploader(t)
        u.sleep = { waits.add($0) }
        #expect(try await u.upload(Data("01".utf8), name: "x").id == "D1")
        #expect(waits.all == [.seconds(1), .seconds(2)])

        let busy = ScriptedTransport()
        busy.handler = { _ in .http(429) }
        await #expect(throws: DriveUploadError.rateLimited) { try await uploader(busy).upload(Data("01".utf8), name: "x") }
    }

    nonisolated final class WaitLog: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Duration] = []
        func add(_ d: Duration) { lock.withLock { waits.append(d) } }
        var all: [Duration] { lock.withLock { waits } }
    }

    @Test func missingScopeMeansSignInAgainAndADisabledAPIIsNoRetry() async {
        let scope = ScriptedTransport([.http(403, #"{"error":{"code":403,"message":"Insufficient Permission","errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#)])
        await #expect(throws: DriveUploadError.scopeInsufficient) { try await uploader(scope).upload(Data("01".utf8), name: "x") }
        #expect(scope.sent.count == 1)
        let off = ScriptedTransport([.http(403, #"{"error":{"code":403,"message":"Google Drive API has not been used in project 1 before or it is disabled.","errors":[{"reason":"accessNotConfigured"}],"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#)])
        await #expect(throws: DriveUploadError.apiDisabled) { try await uploader(off).upload(Data("01".utf8), name: "x") }
        #expect(off.sent.count == 1)
        #expect(PinExportModel.failure(DriveUploadError.scopeInsufficient) == .scopeNotGranted)
        #expect(PinExportFailure.scopeNotGranted.retryTitle == "Sign in again")
        #expect(PinExportModel.failure(DriveUploadError.apiDisabled) == .driveUnavailable)
        #expect(PinExportFailure.driveUnavailable.retryTitle == nil && PinExportFailure.driveUnavailable.offersFile)
    }

    /// A 308 confirming every byte: ask the session (empty body), never send
    /// an empty chunk with "bytes 10-9/10".
    @Test func aRangeCoveringEverythingAsksInsteadOfSendingNothing() async throws {
        let t = ScriptedTransport([
            .http(200, headers: ["Location": session]),
            .http(308, headers: ["Range": "bytes=0-9"]),
            .http(200, done),
        ])
        var u = uploader(t)
        u.chunkSize = 64
        #expect(try await u.upload(Data("0123456789".utf8), name: "x").id == "D1")
        let query = try #require(t.sent.last)
        #expect(query.value(forHTTPHeaderField: "Content-Range") == "bytes */10")
        #expect(query.httpBody == Data())
        #expect(query.value(forHTTPHeaderField: "Content-Length") == "0")
    }

    @Test func tooLargeIsRefusedBeforeSending() async {
        let t = ScriptedTransport()
        var u = uploader(t)
        u.maxBytes = 8
        await #expect(throws: DriveUploadError.tooLarge) { try await u.upload(Data("0123456789".utf8), name: "x") }
        #expect(t.sent.isEmpty)
    }

    @Test func aRefusedConversionIsSaidAsSuch() async {
        let t = ScriptedTransport([
            .http(200, headers: ["Location": session]),
            .http(400, #"{"error":{"code":400,"message":"Unable to convert the file to a Google Docs document.","errors":[{"reason":"badRequest"}]}}"#),
        ])
        await #expect(throws: DriveUploadError.conversionFailed) { try await uploader(t).upload(Data("01".utf8), name: "x") }
    }

    @Test func anExpiredSessionStartsOnceMore() async throws {
        let t = ScriptedTransport([
            .http(200, headers: ["Location": session]),
            .http(404),
            .http(200, headers: ["Location": session]),
            .http(200, done),
        ])
        #expect(try await uploader(t).upload(Data("01".utf8), name: "x").id == "D1")
        #expect(t.sent.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test func aMissingLinkFallsBackToTheDocURL() throws {
        #expect(try DriveUploader.file(from: Data(#"{"id":"D9"}"#.utf8)).webViewLink.absoluteString == "https://docs.google.com/document/d/D9/edit")
    }

    @Test func cancellingStopsBetweenChunks() async {
        let t = ScriptedTransport()
        t.handler = { r in
            if r.httpMethod == "POST" { return .http(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=U"]) }
            let range = r.value(forHTTPHeaderField: "Content-Range") ?? ""
            let end = range.split(separator: "-").last?.split(separator: "/").first.flatMap { Int($0) } ?? 0
            return .http(308, headers: ["Range": "bytes=0-\(end)"])
        }
        t.delay = .milliseconds(20)
        let u = uploader(t)
        let task = Task.detached { try await u.upload(Data(repeating: 7, count: 4000), name: "x") }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(t.sent.count < 100)
    }
}

@MainActor
@Suite struct PinExportFailureTests {
    /// A failure that needs a new sign-in forgets the tokens at once, so a
    /// detour through "Share file instead…" and back signs in afresh.
    @Test func aRefusedGrantIsForgottenRightAway() async throws {
        let store = PinStore.inMemory(defaults: UserDefaults(suiteName: "izzymap-forget-\(UUID().uuidString)")!)
        store.addPin(latitude: -42.88, longitude: 147.32, placedBy: .map)
        let snapshot = PinExportSnapshot.make(project: nil, pins: store.pins(in: nil))
        let transport = ScriptedTransport([
            .http(200, #"{"access_token":"A1","expires_in":3599}"#),
            .http(403, #"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"#),
        ])
        let tokens = MemoryTokenStore("R1")
        let drive = GoogleDrive(auth: GoogleAuth(config: config, transport: transport, store: tokens), transport: transport)
        let model = PinExportModel(container: store.container)
        model.exportToGoogle(snapshot, drive: drive, projectKey: "unfiled") { _, _ in throw CancellationError() }
        for _ in 0 ..< 200 where model.phase == .idle || model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.phase == .failed(.scopeNotGranted))
        #expect(tokens.read() == nil && !drive.isConnected)
        #expect(model.escape(), "Escape closes when nothing runs")
    }

    @Test func theOmissionLine() {
        #expect(PinExport.Omitted().sentence == nil)
        #expect(PinExport.Omitted(notOnDevice: 2).sentence == "2 photos weren’t on this device yet and were left out.")
        #expect(PinExport.Omitted(notOnDevice: 1, unreadable: 1).sentence
            == "1 photo wasn’t on this device yet and was left out. 1 photo couldn’t be read and was left out.")
    }

    @Test func errorsMapToPlainWordsAndEveryOneButBuildOffersTheFile() {
        #expect(PinExportModel.failure(URLError(.serverCertificateUntrusted)) == .network(URLError.Code.serverCertificateUntrusted.rawValue))
        #expect(PinExportModel.failure(URLError(.serverCertificateUntrusted))?.offersFile == true)
        #expect(PinExportModel.describe(URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://x/?upload_id=SECRET"])) == "URLError -1011")
        #expect(PinExportModel.failure(DriveUploadError.offline) == .offline)
        #expect(PinExportModel.failure(URLError(.notConnectedToInternet)) == .offline)
        #expect(PinExportModel.failure(DriveUploadError.driveFull) == .driveFull)
        #expect(PinExportModel.failure(GoogleAuthError.signedOut) == .signedOut)
        #expect(PinExportModel.failure(GoogleAuthError.cancelled) == nil, "no message for backing out")
        #expect(PinExportModel.failure(CancellationError()) == nil)
        #expect(PinExportFailure.offline.message == "Google Docs needs the internet. Share the file instead?")
        #expect(PinExportFailure.driveFull.title == "Your Google Drive is full")
        #expect(PinExportFailure.tooLarge(bytes: nil).title == "Too large for Google Docs")
        for f in [PinExportFailure.offline, .signedOut, .unauthorized, .scopeNotGranted, .signInFailed, .driveFull, .rateLimited,
                  .tooLarge(bytes: 60_000_000), .conversionFailed, .server(500)] {
            #expect(f.offersFile)
        }
        #expect(PinExportFailure.signedOut.needsSignIn && PinExportFailure.signedOut.retryTitle == "Sign in again")
    }
}

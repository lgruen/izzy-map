import Foundation

// The upload (docs/PINS_PLAN.md §6): Drive API v3 resumable upload of the
// .docx with Google Docs as the target type, so Drive converts it into a
// native Doc. Sent in chunks (progress, Cancel between chunks); a dropped
// connection asks the session how far it got (`Content-Range: bytes */N`)
// and carries on from there. Every export makes a NEW Doc.

/// The Doc Drive made.
nonisolated struct DriveFile: Sendable, Equatable {
    var id: String
    /// Opens the Doc (the Docs app claims it as a universal link).
    var webViewLink: URL
}

/// What went wrong, in the words the sheet shows. Every case offers the
/// file route.
nonisolated enum DriveUploadError: Error, Equatable {
    /// No connection (and none came back while retrying).
    case offline
    /// Still 401 after a fresh access token.
    case unauthorized
    /// The refresh token is gone or refused: sign in again.
    case signedOut
    /// 403 storageQuotaExceeded.
    case driveFull
    /// 403/429 rate limits that outlasted the retries.
    case rateLimited
    /// Over 50 MB (checked before sending), or 413.
    case tooLarge
    /// Drive refused to turn the file into a Google Doc.
    case conversionFailed
    /// 403 insufficientPermissions / ACCESS_TOKEN_SCOPE_INSUFFICIENT: the
    /// grant lacks drive.file — sign in again.
    case scopeInsufficient
    /// 403 accessNotConfigured / SERVICE_DISABLED: the Drive API is off for
    /// the app's Google Cloud project — nothing she can retry.
    case apiDisabled
    /// Anything else, with the HTTP status.
    case server(Int)
}

/// The resumable-upload state machine over an `HTTPTransport`.
nonisolated struct DriveUploader: Sendable {
    static let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let googleDocType = "application/vnd.google-apps.document"
    static let startURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")!

    let transport: any HTTPTransport
    /// An access token; `true` = refresh first (after a 401).
    let token: @Sendable (_ forceRefresh: Bool) async throws -> String
    /// Chunk size: a multiple of 256 KiB, as Drive requires (tests use less).
    var chunkSize = 8 * 256 * 1024
    /// How many times a rate limit, a 5xx or a dropped connection is retried.
    var retries = 4
    /// Waits between retries (tests: none).
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var maxBytes = PinExport.googleDocsLimit

    /// Uploads `data` as a new Google Doc called `name`; `progress` gets
    /// the fraction sent (0…1). Throws `DriveUploadError`, or
    /// `CancellationError` when the task is cancelled.
    func upload(_ data: Data, name: String, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> DriveFile {
        guard data.count <= maxBytes else { throw DriveUploadError.tooLarge }
        var restarted = false
        while true {
            let session = try await startSession(name: name, size: data.count)
            do {
                return try await send(data, to: session, progress: progress)
            } catch SessionGone.expired where !restarted {
                // the session URL expired (404/410): one fresh start
                restarted = true
            } catch SessionGone.expired {
                throw DriveUploadError.server(404)
            }
        }
    }

    private enum SessionGone: Error { case expired }

    // MARK: Session

    /// POST the metadata; the session URL comes back in `Location`.
    func startSession(name: String, size: Int) async throws -> URL {
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.googleDocType])
        var attempt = 0
        var forced = false
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: Self.startURL)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.docxType, forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = metadata
            let accessToken: String
            do {
                accessToken = try await token(forced)
            } catch GoogleAuthError.signedOut {
                throw DriveUploadError.signedOut
            } catch let error as GoogleAuthError {
                if case let .tokenEndpoint(status, _) = error, status >= 500 { throw DriveUploadError.server(status) }
                throw DriveUploadError.signedOut
            } catch {
                if Self.isOffline(error) { throw DriveUploadError.offline }
                throw error
            }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                guard Self.isOffline(error) else { throw error }
                guard attempt < retries else { throw DriveUploadError.offline }
                attempt += 1
                try await sleep(backoff(attempt))
                continue
            }
            switch response.statusCode {
            case 200, 201:
                guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
                    throw DriveUploadError.server(response.statusCode)
                }
                return url
            case 401 where !forced:
                forced = true
            case 401:
                throw DriveUploadError.unauthorized
            default:
                let failure = Self.failure(status: response.statusCode, body: data)
                guard failure.retry, attempt < retries else { throw failure.error }
                attempt += 1
                try await sleep(backoff(attempt))
            }
        }
    }

    // MARK: Bytes

    /// PUT the bytes chunk by chunk; 308 = carry on from the `Range` it
    /// confirms; 200/201 = done.
    func send(_ data: Data, to session: URL, progress: @escaping @Sendable (Double) async -> Void) async throws -> DriveFile {
        let total = data.count
        var offset = 0
        var attempt = 0
        await progress(0)
        while true {
            try Task.checkCancellation()
            // every byte confirmed but no answer yet: ask, never send an
            // empty chunk with a malformed Content-Range
            if total > 0, offset >= total {
                switch try await status(of: session, total: total) {
                case let .done(file):
                    await progress(1)
                    return file
                case let .resumeAt(next):
                    if next >= total {
                        guard attempt < retries else { throw DriveUploadError.server(308) }
                        attempt += 1
                        try await sleep(backoff(attempt))
                    }
                    offset = next
                    continue
                }
            }
            let end = min(offset + chunkSize, total)
            var request = URLRequest(url: session)
            request.httpMethod = "PUT"
            request.setValue(Self.docxType, forHTTPHeaderField: "Content-Type")
            request.setValue(total == 0 ? "bytes */0" : "bytes \(offset)-\(end - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            request.httpBody = data.subdata(in: offset ..< end)
            let body: Data, response: HTTPURLResponse
            do {
                (body, response) = try await transport.send(request)
            } catch {
                guard Self.isOffline(error) else { throw error }
                // dropped: ask the session where it stands, then go on
                switch try await status(of: session, total: total) {
                case let .done(file):
                    await progress(1)
                    return file
                case let .resumeAt(next):
                    // a drop that moved nothing counts against the retries
                    // (a link that kills big PUTs but passes the status query
                    // must not loop forever)
                    if next <= offset {
                        guard attempt < retries else { throw DriveUploadError.offline }
                        attempt += 1
                        try await sleep(backoff(attempt))
                    } else {
                        attempt = 0
                    }
                    offset = next
                    await progress(Double(offset) / Double(max(total, 1)))
                    continue
                }
            }
            switch response.statusCode {
            case 200, 201:
                await progress(1)
                return try Self.file(from: body)
            case 308:
                let next = Self.nextOffset(response)
                // a chunk that moved nothing counts against the retries
                if next <= offset {
                    guard attempt < retries else { throw DriveUploadError.server(308) }
                    attempt += 1
                    try await sleep(backoff(attempt))
                } else {
                    attempt = 0     // progress: the retries are per stall, not per upload
                }
                offset = next
                await progress(Double(offset) / Double(max(total, 1)))
            case 404, 410:
                throw SessionGone.expired
            default:
                let failure = Self.failure(status: response.statusCode, body: body)
                guard failure.retry, attempt < retries else { throw failure.error }
                attempt += 1
                try await sleep(backoff(attempt))
                switch try await status(of: session, total: total) {
                case let .done(file):
                    await progress(1)
                    return file
                case let .resumeAt(next):
                    offset = next
                }
            }
        }
    }

    enum SessionStatus: Equatable {
        case resumeAt(Int)
        case done(DriveFile)
    }

    /// `PUT` with no body and `Content-Range: bytes */<size>`: 308 with the
    /// bytes it holds, or 200/201 when the last chunk had arrived after
    /// all. Retried with backoff while offline; still offline → `.offline`.
    func status(of session: URL, total: Int) async throws -> SessionStatus {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: session)
            request.httpMethod = "PUT"
            request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.httpBody = Data()
            do {
                let (body, response) = try await transport.send(request)
                switch response.statusCode {
                case 308: return .resumeAt(Self.nextOffset(response))
                case 200, 201: return .done(try Self.file(from: body))
                case 404, 410: throw SessionGone.expired
                default:
                    let failure = Self.failure(status: response.statusCode, body: body)
                    guard failure.retry, attempt < retries else { throw failure.error }
                }
            } catch {
                guard Self.isOffline(error) else { throw error }
                guard attempt < retries else { throw DriveUploadError.offline }
            }
            attempt += 1
            try await sleep(backoff(attempt))
        }
    }

    // MARK: Pieces

    /// 1, 2, 4, 8 s… (Google's exponential backoff), capped at 16 s.
    func backoff(_ attempt: Int) -> Duration { .seconds(min(16, 1 << max(0, attempt - 1))) }

    /// "Range: bytes=0-524287" → 524288; no header → 0 (nothing kept).
    static func nextOffset(_ response: HTTPURLResponse) -> Int {
        guard let range = response.value(forHTTPHeaderField: "Range"),
              let last = range.split(separator: "-").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
        else { return 0 }
        return last + 1
    }

    static func file(from body: Data) throws -> DriveFile {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = json["id"] as? String,
              !id.isEmpty else { throw DriveUploadError.server(200) }
        let link = (json["webViewLink"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://docs.google.com/document/d/\(id)/edit")!
        return DriveFile(id: id, webViewLink: link)
    }

    /// An error status → what to say, and whether a retry may help.
    static func failure(status: Int, body: Data) -> (error: DriveUploadError, retry: Bool) {
        let parsed = GoogleErrorBody(body)
        let reasons = Set(parsed?.reasons ?? [])
        let text = ((parsed?.message ?? "") + " " + reasons.joined(separator: " ")).lowercased()
        if status == 403, !reasons.isDisjoint(with: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]) {
            return (.scopeInsufficient, false)
        }
        if status == 403, !reasons.isDisjoint(with: ["accessNotConfigured", "SERVICE_DISABLED"]) {
            return (.apiDisabled, false)
        }
        if status == 403, reasons.contains("storageQuotaExceeded") || (reasons.contains("quotaExceeded") && text.contains("storage")) {
            return (.driveFull, false)
        }
        if status == 429 || (status == 403 && !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"])) {
            return (.rateLimited, true)
        }
        if status == 413 || (status == 400 && (reasons.contains("uploadTooLarge") || text.contains("too large"))) {
            return (.tooLarge, false)
        }
        if [400, 403, 500].contains(status), text.contains("conver") {
            return (.conversionFailed, false)
        }
        return (.server(status), [500, 502, 503, 504].contains(status))
    }

    /// No connection, or it dropped: worth asking again.
    static func isOffline(_ error: any Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed]
            .contains(url.code)
    }
}

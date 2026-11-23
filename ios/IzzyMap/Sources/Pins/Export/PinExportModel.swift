import Foundation
import Observation
import os
import SwiftData
import UIKit

/// What the export sheet exports: a project's pins (nil: Unfiled) — all
/// of them, or the ones selected in its list.
struct PinExportTarget: Identifiable, Hashable {
    let project: UUID?
    /// nil: every pin of the project.
    let pins: Set<UUID>?

    var id: String { projectKey + ":" + (pins.map { $0.map(\.uuidString).sorted().joined(separator: ",") } ?? "all") }
    /// Keys the last Doc made per project (`GoogleDrive.lastLinks`).
    var projectKey: String { project?.uuidString ?? "unfiled" }
}

/// Why an export didn't finish, in plain words. Every case but `.build`
/// offers the file instead.
nonisolated enum PinExportFailure: Equatable, Sendable {
    case offline
    case signedOut
    case unauthorized
    case scopeNotGranted
    case signInFailed
    case driveFull
    case rateLimited
    case tooLarge(bytes: Int?)
    case conversionFailed
    case server(Int)
    /// The Drive API is off for the app's Google Cloud project.
    case driveUnavailable
    /// Another network failure (a captive portal's certificate, a garbled
    /// answer), with the URLError code.
    case network(Int)
    /// The document itself couldn't be written.
    case build

    var title: String {
        switch self {
        case .offline: "No connection"
        case .signedOut: "Sign in to Google again"
        case .unauthorized: "Google refused the upload"
        case .scopeNotGranted: "Drive access wasn’t allowed"
        case .signInFailed: "Couldn’t sign in to Google"
        case .driveFull: "Your Google Drive is full"
        case .rateLimited: "Google Drive is busy"
        case .tooLarge: "Too large for Google Docs"
        case .conversionFailed: "Google Docs couldn’t convert it"
        case .server: "Google Drive didn’t take it"
        case .driveUnavailable: "Google Drive isn’t available to IzzyMap"
        case .network: "Couldn’t reach Google Drive"
        case .build: "The document couldn’t be made"
        }
    }

    var message: String {
        switch self {
        case .offline: "Google Docs needs the internet. Share the file instead?"
        case .signedOut: "The Google sign-in has expired or was removed. Sign in again, or share the file instead."
        case .unauthorized: "Sign in again, or share the file instead."
        case .scopeNotGranted: "IzzyMap needs permission to create files in your Drive. Sign in again and allow it, or share the file instead."
        case .signInFailed: "Try again, or share the file instead."
        case .driveFull: "Make room in your Drive, or share the file instead."
        case .rateLimited: "Try again in a minute, or share the file instead."
        case let .tooLarge(bytes):
            "Google Docs converts files up to 50 MB\(bytes.map { "; this one is \(StorageText.size($0))" } ?? ""). Share the file instead, or leave the photos out."
        case .conversionFailed: "Share the file instead — it opens in Google Docs, Pages and Word."
        case let .server(status): "Drive answered with error \(status). Try again, or share the file instead."
        case .driveUnavailable: "Google turned down IzzyMap’s access to Drive — the app’s Google Cloud project needs a look. Share the file instead."
        case let .network(code): "The connection failed (error \(code)). Try again, or share the file instead."
        case .build: "Try again. If it keeps failing, export without photos."
        }
    }

    /// The second button: try Google again (signing in first where the
    /// account link is the problem). nil: nothing to retry there.
    var retryTitle: String? {
        switch self {
        case .signedOut, .unauthorized, .scopeNotGranted: "Sign in again"
        case .tooLarge, .conversionFailed, .driveUnavailable: nil
        default: "Try again"
        }
    }

    var needsSignIn: Bool { [.signedOut, .unauthorized, .scopeNotGranted].contains(self) }
    var offersFile: Bool { self != .build }
}

/// The export sheet's state machine: build the .docx (off the main actor,
/// photo by photo), then hand it to the share sheet or upload it to Drive.
/// One job at a time; Cancel (or the sheet closing) stops it.
@MainActor
@Observable
final class PinExportModel {
    enum Phase: Equatable {
        case idle
        case signingIn
        /// Photos done of total (the last step writes the file).
        case building(done: Int, total: Int)
        case uploading(Double)
        case uploaded(DriveFile)
        case failed(PinExportFailure)
    }

    enum Destination { case share, google }

    private(set) var phase: Phase = .idle
    /// Where the running (or last) job was going.
    private(set) var destination: Destination?
    var includePhotos = true
    /// Photos the last file left out: originals not on this device yet
    /// (still arriving from iCloud), and ones that couldn't be read.
    private(set) var omitted = PinExport.Omitted()
    /// The file to hand to the share sheet (set → the sheet presents it;
    /// each request is new, even for the same file).
    var shareRequest: ShareRequest?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last file built, for what, with which option — reused by "Share
    /// file instead" and a second tap.
    @ObservationIgnored private var built: (snapshot: PinExportSnapshot, photos: Bool, url: URL)?
    @ObservationIgnored let container: ModelContainer?
    @ObservationIgnored let now: () -> Date
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "GoogleExport")

    init(container: ModelContainer?, now: @escaping () -> Date = { Date() }) {
        self.container = container
        self.now = now
    }

    var isWorking: Bool {
        switch phase {
        case .signingIn, .building, .uploading: true
        default: false
        }
    }

    // MARK: Share file

    func shareFile(_ snapshot: PinExportSnapshot) {
        // after an upload the result stays (Open in Google Docs, Done)
        let before = phase
        start(.share) { [self] in
            let url = try await file(for: snapshot)
            if case .uploaded = before { show(before) } else { show(.idle) }
            guard !Task.isCancelled else { return }
            shareRequest = ShareRequest(url: url)
        }
    }

    // MARK: Google Docs

    /// Signs in first when needed (or when the failure said so), builds,
    /// uploads; the Doc's link is kept for the session per project.
    func exportToGoogle(_ snapshot: PinExportSnapshot, drive: GoogleDrive, projectKey: String,
                        authenticate: @escaping WebAuthenticator) {
        let forceSignIn = if case let .failed(failure) = phase { failure.needsSignIn } else { false }
        start(.google) { [self] in
            if forceSignIn { drive.auth.forget() }
            do {
                if !drive.isConnected {
                    show(.signingIn)
                    try await drive.signIn(using: authenticate)
                }
                let url = try await file(for: snapshot)
                let data = try Data(contentsOf: url)
                guard data.count <= PinExport.googleDocsLimit else {
                    show(.failed(.tooLarge(bytes: data.count)))
                    return
                }
                show(.uploading(0))
                let name = url.deletingPathExtension().lastPathComponent
                let doc = try await drive.upload(data, name: name) { [weak self] fraction in
                    await self?.uploaded(fraction)
                }
                drive.lastLinks[projectKey] = doc
                show(.uploaded(doc))
            } catch {
                // a refused token isn't kept for later: a detour through
                // "Share file instead…" and back signs in afresh
                if Self.failure(error)?.needsSignIn == true { drive.auth.forget() }
                throw error
            }
        }
    }

    private func uploaded(_ fraction: Double) {
        if case .uploading = phase { show(.uploading(fraction)) }
    }

    /// A job's phase change — dropped when that job was cancelled, so a
    /// stopped job that wakes past an await never overwrites the sheet.
    private func show(_ new: Phase) {
        guard !Task.isCancelled else { return }
        phase = new
    }

    /// Escape (an iPad keyboard): while a job runs it is the sheet's Cancel
    /// — the job stops, the sheet stays; otherwise the sheet closes.
    /// Returns whether to close.
    func escape() -> Bool {
        guard isWorking else { return true }
        cancel()
        return false
    }

    /// Stops the running job (its file, if built, is kept for a retry).
    func cancel() {
        task?.cancel()
        task = nil
        if isWorking { phase = .idle }
    }

    /// Back to the start (after a result or a failure).
    func reset() {
        cancel()
        phase = .idle
    }

    // MARK: Internals

    private func start(_ destination: Destination, _ job: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        self.destination = destination
        // finish an upload that's under way when she leaves the app
        let background = BackgroundTime(name: "Pins export")
        task = Task { [self] in
            defer { background.end() }
            do {
                try await job()
            } catch {
                guard !Task.isCancelled else { return }
                if let failure = Self.failure(error) {
                    Self.logger.notice("export failed: \(Self.describe(error), privacy: .public)")
                    show(.failed(failure))
                } else {
                    show(.idle)    // she backed out of the sign-in
                }
            }
        }
    }

    /// The .docx for `snapshot` — the last one again when nothing changed.
    private func file(for snapshot: PinExportSnapshot) async throws -> URL {
        if let built, built.snapshot == snapshot, built.photos == includePhotos,
           FileManager.default.fileExists(atPath: built.url.path()) {
            return built.url
        }
        guard let container else { throw PinExportBuildError.noStore }
        let photos = includePhotos && snapshot.photoCount > 0
        show(.building(done: 0, total: (photos ? snapshot.photoCount : 0) + 1))
        let started = ContinuousClock.now
        let (data, left) = try await PinExport.build(snapshot, includePhotos: photos, container: container, now: now()) { [weak self] done, total in
            guard let self, case .building = self.phase else { return }
            self.show(.building(done: done, total: total))
        }
        try Task.checkCancellation()
        omitted = left
        let url = try PinExportFiles.write(data, name: PinExport.fileName(stem: snapshot.fileStem, date: now()))
        Self.logger.notice("export built: \(snapshot.pins.count) pins, \(photos ? snapshot.photoCount : 0) photos, \(data.count) bytes in \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        built = (snapshot, includePhotos, url)
        return url
    }

    /// An error → what the sheet says; nil for backing out (no message).
    static func failure(_ error: any Error) -> PinExportFailure? {
        switch error {
        case let e as DriveUploadError:
            switch e {
            case .offline: return .offline
            case .unauthorized: return .unauthorized
            case .signedOut: return .signedOut
            case .driveFull: return .driveFull
            case .rateLimited: return .rateLimited
            case .tooLarge: return .tooLarge(bytes: nil)
            case .conversionFailed: return .conversionFailed
            case .scopeInsufficient: return .scopeNotGranted
            case .apiDisabled: return .driveUnavailable
            case let .server(status): return .server(status)
            }
        case let e as GoogleAuthError:
            switch e {
            case .cancelled: return nil
            case .scopeNotGranted: return .scopeNotGranted
            case .signedOut: return .signedOut
            case .stateMismatch, .keychain, .signInPageFailed: return .signInFailed
            case let .tokenEndpoint(status, _): return status >= 500 ? .server(status) : .signInFailed
            }
        case is CancellationError:
            return nil
        case let e as URLError:
            return DriveUploader.isOffline(e) ? .offline : .network(e.code.rawValue)
        default:
            return .build
        }
    }

    /// For the log: a URLError by its code only (its description holds the
    /// URL — an upload session URL is a capability).
    static func describe(_ error: any Error) -> String {
        if let url = error as? URLError { return "URLError \(url.code.rawValue)" }
        return String(describing: error)
    }
}

/// One trip to the share sheet.
struct ShareRequest: Equatable {
    let url: URL
    let id = UUID()
}

/// The sheet opened without a pin store (can't happen with pins on).
nonisolated enum PinExportBuildError: Error { case noStore }

/// A little background time for a job she started (an upload when she
/// switches apps). Ended when the job ends, or by the system's deadline —
/// an assertion left open would get the app killed.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

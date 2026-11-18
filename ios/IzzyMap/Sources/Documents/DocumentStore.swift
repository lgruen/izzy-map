import Foundation
import IzzyKit

/// A document a card can open: an F2F chapter at a community's page, a
/// City of Hobart tree data sheet, or a soil map sheet's report.
nonisolated enum DocumentRef: Hashable, Sendable, Identifiable {
    /// From Forest to Fjaeldmark chapter `file`, opened at 0-based `page`.
    case f2f(file: String, page: Int, title: String)
    /// An ArcGIS Online item id (the sheet PDF), its declared size.
    case sheet(item: String, title: String, bytes: Int?)
    /// A reconnaissance soil map sheet's report: the sheet key ("hobart"),
    /// the report's URL and size from soil_units.json. Opens at page 1
    /// (the reports have no per-unit page index).
    case soilReport(sheet: String, title: String, url: URL, bytes: Int?)

    var id: String { "\(kind.rawValue)/\(storedName)" }
    var kind: ExtraKind {
        switch self {
        case .f2f: .f2f
        case .sheet: .sheets
        case .soilReport: .soilReports
        }
    }
    var storedName: String {
        switch self {
        case let .f2f(file, _, _): file
        case let .sheet(item, _, _): ExtrasCatalog.sheetFileName(item)
        case let .soilReport(sheet, _, _, _): ExtrasCatalog.soilReportFileName(sheet)
        }
    }
    var title: String {
        switch self {
        case let .f2f(_, _, title), let .sheet(_, title, _), let .soilReport(_, title, _, _): title
        }
    }
    /// 0-based page to open at.
    var page: Int {
        if case let .f2f(_, page, _) = self { return page }
        return 0
    }

    /// Declared size, if known (sizes the whole-transfer ceiling).
    var bytes: Int? {
        switch self {
        case .f2f: nil
        case let .sheet(_, _, bytes), let .soilReport(_, _, _, bytes): bytes
        }
    }

    /// Whether its stored name is a plain file name: a soil report's sheet
    /// key comes from a bundled table and must never become a path
    /// ("../trees/x"). An invalid document has no local file, no gone mark
    /// and no remote URL.
    var isValid: Bool {
        if case let .soilReport(sheet, _, _, _) = self { return ExtrasCatalog.isSoilSheetKey(sheet) }
        return true
    }

    /// The report of soil map sheet `key`, or nil when the key or its URL
    /// may not be used (then the card shows no button).
    static func soilReport(key: String, sheet: SoilsFile.Sheet) -> DocumentRef? {
        guard ExtrasCatalog.soilReportURL(key: key, url: sheet.url) != nil else { return nil }
        return .soilReport(sheet: key, title: "\(sheet.name) sheet soil report", url: sheet.url, bytes: sheet.bytes)
    }

    func remoteURL(f2fBase: String) -> URL? {
        switch self {
        case let .f2f(file, _, _): URL(string: f2fBase + file)
        case let .sheet(item, _, _): ExtrasCatalog.sheetURL(item)
        // only a plain sheet key and an https URL on NRE's data library
        case let .soilReport(sheet, _, url, _): ExtrasCatalog.soilReportURL(key: sheet, url: url)
        }
    }
}

/// Why a document couldn't be opened. Each cause has its own words; our
/// own cancel (the card went away) says nothing.
nonisolated enum DocumentError: Error, Equatable, Sendable {
    case offline, gone, timedOut, notPDF, failed(status: Int?), cancelled

    init(_ verdict: FetchVerdict) {
        switch verdict {
        case .offline: self = .offline
        case .timedOut: self = .timedOut
        case .cancelled: self = .cancelled
        case .gone: self = .gone
        case .captivePortal: self = .notPDF
        case let .skip(status): self = .failed(status: status)
        case .failed, .store: self = .failed(status: nil)
        }
    }

    /// The message for `doc`, nil for our own cancel. `sheetsTotal` is the
    /// size of all of the document's family (tree sheets, soil reports).
    func message(for doc: DocumentRef, device: String, sheetsTotal: Int?) -> String? {
        let all = sheetsTotal.map { " (\(ExtrasText.megabytes($0)))" } ?? ""
        switch self {
        case .cancelled: return nil
        case .offline:
            switch doc.kind {
            case .sheets:
                return "This data sheet isn’t on the \(device) yet — open it once while online, or get all sheets\(all) in Storage."
            case .soilReports:
                return "This soil report isn’t on the \(device) yet — open it once while online, or get all soil reports\(all) in Storage."
            case .f2f, .photos:
                return "This description isn’t on the \(device) yet — open it once while online, or get all descriptions in Storage."
            }
        case .gone:
            switch doc.kind {
            case .sheets: return "This data sheet is no longer published by the council."
            case .soilReports: return "This soil report isn’t at its usual address in NRE Tasmania’s data library any more."
            case .f2f, .photos: return "This chapter isn’t at its usual address on nre.tas.gov.au any more."
            }
        case .timedOut:
            switch doc.kind {
            case .sheets: return "Fetching the data sheet took too long — try again on Wi-Fi."
            case .soilReports: return "Fetching the soil report took too long — try again on Wi-Fi."
            case .f2f, .photos: return "Fetching the description took too long — try again on Wi-Fi."
            }
        case .notPDF:
            return "The download wasn’t a PDF — a Wi-Fi login page may be in the way."
        case let .failed(status):
            return "Couldn’t download" + (status.map { " (HTTP \($0))" } ?? "") + " — try again later."
        }
    }
}

/// F2F chapters, tree sheets and soil reports on the device: opened from
/// disk, else fetched once from the publisher (nre.tas.gov.au,
/// www.arcgis.com, nrmdatalibrary.nre.tas.gov.au),
/// checked for the %PDF magic (a captive portal answers 200 HTML) AND that
/// PDFKit opens it with at least one page (a truncated body is a failed
/// transfer), kept. A stored file that no longer opens is fetched again.
/// One fetch per document at a time: a second caller joins the first. A
/// fetch is cancelled when every caller waiting for it has gone away (the
/// card's selection changed). A fetch that lands after Delete is dropped
/// (`ExtrasStorage` generations).
actor DocumentStore {
    static let shared = DocumentStore(storage: .shared)

    let storage: ExtrasStorage
    /// Tap fetches: 30 s without a byte is a stall (a stalled cellular
    /// fetch must not hold the button for ever); the whole transfer may
    /// take what the document's declared size needs on a slow link
    /// (`ExtrasTimeouts`: 10 min, 40 min for the 20 MB South Esk report).
    static let timeout: TimeInterval = 30
    /// A test's session, used for every document; else one per ceiling.
    private let injected: URLSession?
    private var sessions: [TimeInterval: URLSession] = [:]
    private var f2fBase = "https://nre.tas.gov.au/Documents/"

    private struct Inflight {
        let task: Task<Result<URL, DocumentError>, Never>
        var waiters: Int
    }
    private var inflight: [String: Inflight] = [:]

    init(storage: ExtrasStorage, session: URLSession? = nil) {
        self.storage = storage
        injected = session
    }

    /// The whole-transfer ceiling for `doc` (its session's resource timeout).
    nonisolated static func resourceTimeout(for doc: DocumentRef) -> TimeInterval {
        ExtrasTimeouts.resourceCeiling(bytes: doc.bytes)
    }

    /// The session a fetch of `doc` uses (internal for the tests).
    func session(for doc: DocumentRef) -> URLSession {
        if let injected { return injected }
        let ceiling = Self.resourceTimeout(for: doc)
        if let s = sessions[ceiling] { return s }
        let s = ExtrasNetwork.session(timeout: Self.timeout, resourceTimeout: ceiling)
        sessions[ceiling] = s
        return s
    }

    func setF2FBase(_ base: String) { f2fBase = base }

    /// The document on the device, if there.
    nonisolated func localURL(_ doc: DocumentRef) -> URL? {
        guard doc.isValid else { return nil }
        return storage.existing(doc.kind, doc.storedName)
    }

    /// Whether the publisher withdrew it (last time anyone asked).
    nonisolated func isGone(_ doc: DocumentRef) -> Bool {
        doc.isValid && storage.goneMarks(doc.kind).contains(doc.storedName)
    }

    /// Drops the stored copy (it didn't open in the reader).
    func discard(_ doc: DocumentRef) {
        if let local = localURL(doc) { try? FileManager.default.removeItem(at: local) }
    }

    /// The local file, fetching it first if needed. A gone document is
    /// still tried (items get republished); a success forgets the mark.
    func open(_ doc: DocumentRef) async throws(DocumentError) -> URL {
        if let local = localURL(doc) {
            if DocumentCheck.opens(local) { return local }
            // kept before the page check existed, or damaged since: fetch again
            try? FileManager.default.removeItem(at: local)
        }
        let key = doc.id
        if inflight[key] == nil {
            let task = Task { await self.fetch(doc) }
            inflight[key] = Inflight(task: task, waiters: 0)
        }
        inflight[key]!.waiters += 1
        let task = inflight[key]!.task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(key) }
        }
        if Task.isCancelled { throw .cancelled }
        leaveIfDone(key, task: task)
        return try result.get()
    }

    /// A waiter gave up; the last one out cancels the fetch.
    private func leave(_ key: String) {
        guard var entry = inflight[key] else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inflight[key] = nil
        } else {
            inflight[key] = entry
        }
    }

    private func leaveIfDone(_ key: String, task: Task<Result<URL, DocumentError>, Never>) {
        guard var entry = inflight[key], entry.task == task else { return }
        entry.waiters -= 1
        inflight[key] = entry.waiters <= 0 ? nil : entry
    }

    private func fetch(_ doc: DocumentRef) async -> Result<URL, DocumentError> {
        guard let url = doc.remoteURL(f2fBase: f2fBase) else { return .failure(.failed(status: nil)) }
        // stamped now: a Delete while this is in flight retires it
        let generation = storage.generation(doc.kind)
        let (result, file) = await ExtrasNetwork.fetch(url, kind: doc.kind, session: session(for: doc))
        // a tap cares only whether THIS file is a PDF: a sheet's 200 HTML is
        // a login page here, not a withdrawal (the batch decides "gone")
        var verdict = FetchVerdict.of(result, kind: doc.kind)
        if case let .response(status, head, allowed) = result, (200 ..< 300).contains(status),
           !(allowed && ContentSniff.isPDF(head)) {
            verdict = .captivePortal
        }
        if Task.isCancelled { verdict = .cancelled }
        guard verdict == .store, let file else {
            if let file { try? FileManager.default.removeItem(at: file) }
            if verdict == .gone { storage.updateGone(doc.kind) { $0.mark(doc.storedName) } }
            return .failure(DocumentError(verdict))
        }
        do {
            // adopt removes the download itself when it can't keep it
            let stored = try storage.adopt(file, as: doc.kind, doc.storedName, generation: generation)
            storage.updateGone(doc.kind) { $0.forget(doc.storedName) }
            return .success(stored)
        } catch ExtrasStorage.AdoptError.deleted {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(status: nil))
        }
    }
}

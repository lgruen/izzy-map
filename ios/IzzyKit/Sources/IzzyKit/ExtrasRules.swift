import Foundation

// The licensed extras (docs/LICENSING.md §2, NATIVE_PLAN.md §2): F2F
// chapters, Understorey Network photos and City of Hobart tree data
// sheets. All rights reserved upstream — the DEVICE fetches them from the
// publisher for private use; never bundled, committed or hosted by us.
// These are the pure rules (what counts as done, gone, a captive portal);
// the app's network layer applies them.

/// The three kinds of extra.
public enum ExtraKind: String, Codable, Sendable, CaseIterable, Hashable {
    case f2f, photos, sheets

    /// Folder under the extras root.
    public var folder: String {
        switch self {
        case .f2f: "f2f"
        case .photos: "plants"
        case .sheets: "trees"
        }
    }

    /// What every stored file must start with.
    public var expected: ContentSniff.Kind { self == .photos ? .image : .pdf }

    /// Batch rules per kind (inventory §6, carried over from the web app).
    public var policy: ExtrasPolicy {
        switch self {
        // 11 chapters, one at a time; nre.tas.gov.au answers 404 for a
        // renamed file — three of those in a row is the site, not deletions
        case .f2f: ExtrasPolicy(concurrency: 1, goneStatuses: .allClientErrors, goneStreakLimit: 3,
                                wrongTypeIsGone: false, retries: 2)
        // 997 photos, 4 at a time; only a readable 404/410 is "gone"; ten
        // in a row = a broken path scheme
        case .photos: ExtrasPolicy(concurrency: 4, goneStatuses: .notFoundOnly, goneStreakLimit: 10,
                                   wrongTypeIsGone: false, retries: 2)
        // 282 sheets; ArcGIS answers a REMOVED item with HTTP 400 + HTML —
        // any 4xx, and a non-PDF body, is gone; five in a row = a captive
        // portal or a 403 wall
        case .sheets: ExtrasPolicy(concurrency: 2, goneStatuses: .allClientErrors, goneStreakLimit: 5,
                                   wrongTypeIsGone: true, retries: 2)
        }
    }
}

public struct ExtrasPolicy: Sendable, Hashable {
    public enum GoneStatuses: Sendable, Hashable { case allClientErrors, notFoundOnly }
    /// Files in flight at once (the window the transport is fed in).
    public var concurrency: Int
    public var goneStatuses: GoneStatuses
    /// This many "gone" in a row undo their marks and stop the batch.
    public var goneStreakLimit: Int
    /// A 200 with the wrong content: gone (sheets: a removed item may
    /// answer 200 HTML) or a captive portal (stop).
    public var wrongTypeIsGone: Bool
    /// A stalled or broken transfer of one file (timeout, dropped
    /// connection, a body that doesn't open) is tried again this many
    /// times before it counts: a timeout then stops the batch ("needs
    /// reception"), any other failure skips the file for the session.
    /// "No network path" is never retried — it stops at once.
    public var retries: Int

    public func isGone(status: Int) -> Bool {
        switch goneStatuses {
        case .allClientErrors: (400 ..< 500).contains(status)
        case .notFoundOnly: status == 404 || status == 410
        }
    }
}

/// Magic-byte checks: a captive portal answers 200 with an HTML login page.
public enum ContentSniff {
    public enum Kind: Sendable, Hashable { case pdf, image }

    public static func matches(_ head: Data, _ kind: Kind) -> Bool {
        kind == .pdf ? isPDF(head) : isImage(head)
    }

    /// "%PDF".
    public static func isPDF(_ head: Data) -> Bool { head.starts(with: [0x25, 0x50, 0x44, 0x46]) }

    /// JPEG (FF D8 FF), PNG (89 'PNG'), WebP ('RIFF' … 'WEBP'), GIF ('GIF8').
    public static func isImage(_ head: Data) -> Bool {
        let b = [UInt8](head.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if b.starts(with: Array("GIF8".utf8)) { return true }
        return b.count >= 12 && b.starts(with: Array("RIFF".utf8)) && Array(b[8 ..< 12]) == Array("WEBP".utf8)
    }
}

/// What one fetch came to, before any rule is applied.
public enum FetchResult: Sendable, Hashable {
    /// HTTP status, the first bytes of the body, and whether the final URL
    /// stayed on an allowed host (a redirect off-site is never stored).
    case response(status: Int, head: Data, allowedHost: Bool)
    /// No network path (or the host is unreachable).
    case offline
    case timedOut
    /// Our own cancel.
    case cancelled
    /// Any other transport failure.
    case failed
}

/// One fetch's verdict under a kind's rules.
public enum FetchVerdict: Sendable, Hashable {
    /// Store the body; forget any gone mark.
    case store
    /// Withdrawn upstream: mark gone (dated), counts as done.
    case gone
    /// A 200 that isn't the expected file type, or a redirect off-site:
    /// a Wi-Fi login page is in the way — stop, store nothing.
    case captivePortal
    /// A server error (5xx, other 4xx for photos): skip for this session.
    case skip(status: Int)
    case offline
    case timedOut
    case cancelled
    case failed

    /// Nothing was learned about the file itself — no reception, a stall,
    /// our own cancel, a login page in the way: ask again later this
    /// session (e.g. when it's next shown), never remember it as failed.
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .cancelled, .captivePortal: true
        case .store, .gone, .skip, .failed: false
        }
    }

    public static func of(_ result: FetchResult, kind: ExtraKind) -> FetchVerdict {
        switch result {
        case .offline: return .offline
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .failed: return .failed
        case let .response(status, head, allowedHost):
            if (200 ..< 300).contains(status) {
                guard allowedHost else { return .captivePortal }
                if ContentSniff.matches(head, kind.expected) { return .store }
                return kind.policy.wrongTypeIsGone ? .gone : .captivePortal
            }
            if kind.policy.isGone(status: status) { return .gone }
            return .skip(status: status)
        }
    }
}

/// Withdrawn files, remembered with the date they were found gone (a
/// Codable file in the app's storage — the web app's localStorage sets).
public struct GoneMarks: Codable, Sendable, Hashable {
    public var marks: [String: Date]

    public init(_ marks: [String: Date] = [:]) { self.marks = marks }

    public func contains(_ id: String) -> Bool { marks[id] != nil }
    public mutating func mark(_ id: String, on date: Date = .now) { marks[id] = date }
    public mutating func forget(_ id: String) { marks[id] = nil }
    public var count: Int { marks.count }

    /// Applies what changed from `before` to `after` (a batch's own copy)
    /// onto these marks — the file's current state, which a tap may have
    /// changed meanwhile. Never overwrites marks the batch didn't touch.
    public mutating func apply(from before: GoneMarks, to after: GoneMarks) {
        for (id, date) in after.marks where before.marks[id] != date { marks[id] = date }
        for id in before.marks.keys where after.marks[id] == nil { marks[id] = nil }
    }
}

/// One file of a batch.
public struct ExtraItem: Sendable, Hashable, Identifiable {
    /// Stored file name (also the gone-mark key).
    public var id: String
    public var url: URL
    /// Declared size, if known.
    public var bytes: Int?

    public init(id: String, url: URL, bytes: Int?) {
        self.id = id
        self.url = url
        self.bytes = bytes
    }
}

/// The batches, from the bundled tables.
public enum ExtrasCatalog {
    /// The 11 F2F chapters, with their sizes from the index (30.4 MB in
    /// all, 2026-11).
    public static func f2f(_ index: F2FIndex) -> [ExtraItem] {
        index.chapterFiles.compactMap { file in
            URL(string: index.baseUrl + file).map { ExtraItem(id: file, url: $0, bytes: index.sizes?[file]) }
        }
    }
    /// Size of all chapters for the space preflight when an index carries
    /// no sizes (measured 2026-11-03: 30,447,114 bytes).
    public static let f2fTotalBytes = 30_447_114

    /// Every listed photo's large version, once per stored name.
    public static func photos(_ plants: [Plant]) -> [ExtraItem] {
        var seen = Set<String>()
        var out: [ExtraItem] = []
        for p in plants {
            for ph in p.photos where seen.insert(ph.storedName).inserted {
                if let url = ph.largeURL { out.append(ExtraItem(id: ph.storedName, url: url, bytes: ph.bytes)) }
            }
        }
        return out
    }

    /// Every tree data sheet, sorted by id (the bulk order).
    public static func sheets(_ trees: TreesData) -> [ExtraItem] {
        trees.sheets.keys.sorted().compactMap { id in
            sheetURL(id).map { ExtraItem(id: sheetFileName(id), url: $0, bytes: trees.sheets[id]?.bytes) }
        }
    }

    /// The only arcgis.com form that answers for a sheet item (the
    /// hobartcc.maps.arcgis.com URL in the service data is not used).
    public static func sheetURL(_ itemID: String) -> URL? {
        guard itemID.allSatisfy({ $0.isHexDigit }), !itemID.isEmpty else { return nil }
        return URL(string: "https://www.arcgis.com/sharing/rest/content/items/\(itemID)/data")
    }

    public static func sheetFileName(_ itemID: String) -> String { itemID + ".pdf" }

    /// Hosts a final URL may end on. ArcGIS redirects to signed S3; F2F and
    /// photos are fetched straight from the publisher, redirects off it are
    /// never stored.
    public static func allows(host: String?, for kind: ExtraKind) -> Bool {
        guard let host = host?.lowercased() else { return false }
        switch kind {
        case .f2f: return host == "nre.tas.gov.au"
        case .photos: return host == PlantPhoto.host
        case .sheets:
            return host == "www.arcgis.com" || host.hasSuffix(".amazonaws.com") || host.hasSuffix(".arcgis.com")
        }
    }

    /// Σ declared sizes; an unknown size counts at the mean of the known ones.
    public static func totalBytes(_ items: [ExtraItem]) -> Int {
        let known = items.compactMap(\.bytes)
        guard !known.isEmpty else { return 0 }
        let mean = Double(known.reduce(0, +)) / Double(known.count)
        return items.reduce(0) { $0 + ($1.bytes ?? Int(mean.rounded())) }
    }
}

/// Where a batch stands: what's done, what's left, and when to stop.
/// A value type driven by the network layer, one completion at a time.
public struct ExtrasBatch: Sendable {
    public enum Stop: Sendable, Hashable {
        /// Cancel, our own.
        case cancelled
        case offline
        /// A Wi-Fi login page answered (wrong content type, or too many
        /// "gone" in a row for deletions to be the explanation).
        case captivePortal
        /// Not enough free space before starting.
        case needsSpace(bytes: Int)
    }

    public enum Phase: Sendable, Hashable {
        case running
        /// Every file present or gone (or skipped this session).
        case finished
        case stopped(Stop)
    }

    public let kind: ExtraKind
    public let items: [ExtraItem]
    /// Files still to finish, in order (including those in flight).
    public private(set) var todo: [ExtraItem]
    /// Files the transport is fetching now (at most `concurrency`, plus any
    /// a previous launch left running).
    public private(set) var inFlight: Set<String> = []
    /// Failed transfers per file so far (`ExtrasPolicy.retries`).
    private var attempts: [String: Int] = [:]
    public private(set) var gone: GoneMarks
    public private(set) var present: Set<String>
    /// Server errors this session (skipped until the app opens again).
    public private(set) var skipped: Set<String>
    public private(set) var phase: Phase = .running
    /// Gone ids since the last stored file (undone together past the limit).
    private var streak: [String] = []
    private let mean: Int

    public init(kind: ExtraKind, items: [ExtraItem], present: Set<String>, gone: GoneMarks,
                skippedThisSession: Set<String> = []) {
        self.kind = kind
        self.items = items
        self.present = present
        self.gone = gone
        skipped = skippedThisSession
        todo = items.filter { !present.contains($0.id) && !gone.contains($0.id) && !skippedThisSession.contains($0.id) }
        let known = items.compactMap(\.bytes)
        mean = known.isEmpty ? 0 : known.reduce(0, +) / known.count
        if todo.isEmpty { phase = .finished }
    }

    public var totalBytes: Int { ExtrasCatalog.totalBytes(items) }
    /// Bytes on the device (declared sizes; unknown at the mean).
    public var bytesPresent: Int { items.filter { present.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? mean) } }
    /// Present or gone: "file n of N".
    public var done: Int { items.filter { present.contains($0.id) || gone.contains($0.id) }.count }
    public var goneCount: Int { items.filter { gone.contains($0.id) }.count }
    public var skippedCount: Int { items.filter { skipped.contains($0.id) }.count }
    /// Bytes still to fetch (the space preflight's need).
    public var bytesRemaining: Int { todo.reduce(0) { $0 + ($1.bytes ?? mean) } }

    /// Refuse to start without room for what's left plus a margin.
    public mutating func preflight(freeBytes: Int64?, margin: Int64 = 200_000_000) {
        guard let freeBytes, phase == .running else { return }
        let need = Int64(kind == .f2f && totalBytes == 0
            ? ExtrasCatalog.f2fTotalBytes * todo.count / max(1, items.count) : bytesRemaining)
        if freeBytes < need + margin { phase = .stopped(.needsSpace(bytes: Int(need))) }
    }

    public mutating func cancel() {
        if phase == .running { phase = .stopped(.cancelled) }
    }

    /// The next file to start: nil while `concurrency` files are in flight,
    /// when nothing waits, or once the batch has stopped. The caller starts
    /// what this returns and calls again (the window refills one
    /// completion at a time).
    public mutating func nextToStart() -> ExtraItem? {
        guard phase == .running, inFlight.count < kind.policy.concurrency,
              let item = todo.first(where: { !inFlight.contains($0.id) }) else { return nil }
        inFlight.insert(item.id)
        return item
    }

    /// A file already on its way (a task an earlier launch or batch left
    /// running): not started again; its completion counts here. False when
    /// the batch has nothing to do for it.
    @discardableResult
    public mutating func markInFlight(_ id: String) -> Bool {
        guard phase == .running, todo.contains(where: { $0.id == id }) else { return false }
        inFlight.insert(id)
        return true
    }

    /// Apply one completion. Returns the verdict (the caller stores the
    /// body for `.store`, and cancels outstanding work once `phase` stops).
    /// A completion for a file the batch isn't waiting for changes nothing.
    @discardableResult
    public mutating func record(_ id: String, _ result: FetchResult, on date: Date = .now) -> FetchVerdict {
        let verdict = FetchVerdict.of(result, kind: kind)
        guard phase == .running, todo.contains(where: { $0.id == id }) else { return verdict }
        inFlight.remove(id)
        if verdict == .timedOut || verdict == .failed {
            let tried = attempts[id, default: 0]
            if tried < kind.policy.retries {
                // one stalled or broken transfer: the file stays first in
                // line and goes out again with the next window
                attempts[id] = tried + 1
                return verdict
            }
        }
        todo.removeAll { $0.id == id }
        switch verdict {
        case .store:
            present.insert(id)
            gone.forget(id)
            streak = []
        case .gone:
            gone.mark(id, on: date)
            streak.append(id)
            if streak.count >= kind.policy.goneStreakLimit {
                // a run this long is a login wall or a broken path scheme,
                // not deletions: undo the marks, fetch them again next time
                for s in streak { gone.forget(s) }
                streak = []
                phase = .stopped(.captivePortal)
                return .captivePortal
            }
        case .captivePortal:
            phase = .stopped(.captivePortal)
        case .skip, .failed:
            // a server error, or a transfer that failed every retry: skip
            // just this file until the app opens again
            skipped.insert(id)
        case .offline, .timedOut:
            // no network path, or one file stalled through every retry:
            // stop, keep what arrived; Resume continues
            phase = .stopped(.offline)
        case .cancelled:
            phase = .stopped(.cancelled)
        }
        if phase == .running, todo.isEmpty { phase = .finished }
        return verdict
    }

    /// The row's one-line status.
    public var statusText: String {
        let unit = kind.unit
        switch phase {
        case .running:
            return "\(kind.noun) \(min(done + 1, items.count)) of \(items.count) · \(ExtrasText.megabytes(bytesPresent)) of \(ExtrasText.megabytes(totalBytes))"
        case .finished:
            var parts = ["✓ downloaded"]
            if goneCount > 0 { parts.append(kind.goneText(goneCount)) }
            if skippedCount > 0 {
                parts.append("\(skippedCount) \(skippedCount == 1 ? unit : unit + "s") failed, will retry next time the app opens")
            }
            return parts.joined(separator: " · ")
        case let .stopped(stop):
            switch stop {
            case .cancelled: return "\(ExtrasText.megabytes(bytesPresent)) of \(ExtrasText.megabytes(totalBytes)) on this device"
            case .offline: return "Stopped — needs reception. What arrived is kept."
            case .captivePortal: return "Stopped — a Wi-Fi login page may be in the way."
            case let .needsSpace(bytes): return "Not enough free space — needs about \(ExtrasText.megabytes(bytes)) free."
            }
        }
    }
}

extension ExtraKind {
    var noun: String {
        switch self {
        case .f2f: "chapter"
        case .photos: "photo"
        case .sheets: "sheet"
        }
    }
    var unit: String { noun }

    func goneText(_ n: Int) -> String {
        let s = n == 1 ? noun : noun + "s"
        switch self {
        case .f2f: return "\(n) \(s) no longer published"
        case .photos: return "\(n) no longer on the Understorey Network site"
        case .sheets: return "\(n) \(s) no longer published"
        }
    }
}

public enum ExtrasText {
    /// "152 MB", "0.6 MB" under 10 MB (sheets run 0.1–7 MB).
    public static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1e6
        return (mb < 10 ? String(format: "%.1f", mb) : String(Int(mb.rounded()))) + "\u{00A0}MB"
    }
}

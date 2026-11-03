import IzzyKit
import Observation
import SwiftUI

/// One window's document state: which documents are being fetched, the
/// reader on screen (and its page), the last failure. It lives with the
/// window's model, not with a button, so:
/// - a fetch lasts as long as the card's SELECTION, not the button's view —
///   a plant sheet pushed over the card (which parks the button) doesn't
///   cancel it; a new tap on the map or a close does (`selectionChanged`);
/// - the reader is presented by the active layout's host (`ReaderHost`) and
///   survives a sheet ↔ card switch at the page it was on;
/// - Escape knows it is up (`AppModel.escapeStep`: the reader first).
@MainActor @Observable
final class DocumentOpener {
    /// The reader's document, the file it shows and its current page
    /// (0-based; the host re-presents at this page after a layout switch).
    struct Reading: Identifiable, Equatable {
        let doc: DocumentRef
        let url: URL
        var page: Int
        /// Bumped by "Download again": a new file, a fresh reader.
        var attempt = 0
        var id: String { "\(doc.id)#\(attempt)" }
    }

    /// A failed fetch, worded for its document.
    struct Failure: Identifiable, Equatable {
        let doc: DocumentRef
        let title: String
        let message: String
        var id: String { doc.id }
    }

    var reading: Reading?
    var failure: Failure?
    /// Documents being fetched now (by id).
    private(set) var fetching: Set<String> = []
    /// Bumped whenever a document lands on the device (buttons re-check).
    private(set) var revision = 0
    /// Haptic trigger for a failure.
    private(set) var failures = 0

    @ObservationIgnored private let store: DocumentStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(store: DocumentStore = .shared) { self.store = store }

    var isReading: Bool { reading != nil }

    /// A button's tap: open from the device, else fetch it once and open it
    /// unless the card changed meanwhile.
    func open(_ doc: DocumentRef, title: String, sheetsTotal: Int?) {
        if let local = store.localURL(doc) {
            reading = Reading(doc: doc, url: local, page: doc.page)
            return
        }
        fetch(doc, title: title, sheetsTotal: sheetsTotal, page: doc.page)
    }

    private func fetch(_ doc: DocumentRef, title: String, sheetsTotal: Int?, page: Int, attempt: Int = 0) {
        guard tasks[doc.id] == nil else { return }
        fetching.insert(doc.id)
        let store = store
        tasks[doc.id] = Task { [weak self] in
            let outcome: Result<URL, DocumentError>
            do throws(DocumentError) { outcome = .success(try await store.open(doc)) } catch { outcome = .failure(error) }
            guard let self else { return }
            self.tasks[doc.id] = nil
            self.fetching.remove(doc.id)
            guard !Task.isCancelled else { return }
            switch outcome {
            case let .success(url):
                self.revision += 1
                self.reading = Reading(doc: doc, url: url, page: page, attempt: attempt)
            case let .failure(error):
                if let message = error.message(for: doc, device: DeviceNoun.current, sheetsTotal: sheetsTotal) {
                    self.failure = Failure(doc: doc, title: title, message: message)
                    self.failures += 1
                }
            }
        }
    }

    func isFetching(_ doc: DocumentRef) -> Bool { fetching.contains(doc.id) }

    /// The reader couldn't open its stored file: drop it and fetch again,
    /// at the same page.
    func downloadAgain() {
        guard let reading else { return }
        let doc = reading.doc
        let page = reading.page
        let attempt = reading.attempt + 1
        self.reading = nil
        Task {
            await store.discard(doc)
            revision += 1
            fetch(doc, title: doc.title, sheetsTotal: nil, page: page, attempt: attempt)
        }
    }

    func closeReader() { reading = nil }

    /// A new card (or none): its fetches end; an old failure is moot.
    func selectionChanged() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        fetching = []
        failure = nil
    }
}

/// Presents the window's reader and fetch failures from ONE container: the
/// sheet layout hosts them on the panel sheet (the topmost presented
/// controller), the card layout on the root — like `ModalHost`. Unlike a
/// modal, the reader is not dropped on a layout switch: the new layout's
/// host presents the same document again, at the page it was on.
struct ReaderHost: ViewModifier {
    let model: AppModel
    let layout: PanelLayout

    func body(content: Content) -> some View {
        let opener = model.documents
        content
            .fullScreenCover(item: Binding(
                get: { model.panelLayout == layout ? opener.reading : nil },
                // only this host's own dismissal clears it (not the old host
                // going away with its layout)
                set: { if $0 == nil, model.panelLayout == layout { opener.closeReader() } }
            )) { reading in
                PDFReader(opener: opener, reading: reading)
                #if DEBUG
                    // UI tests: what the window's Escape does now (XCUITest's
                    // synthesized Escape never reaches the app on the simulator)
                    .accessibilityValue(model.escapeStep?.title ?? "")
                #endif
            }
            .alert(opener.failure?.title ?? "", isPresented: Binding(
                get: { model.panelLayout == layout && opener.failure != nil && opener.reading == nil },
                set: { if !$0, model.panelLayout == layout { opener.failure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(opener.failure?.message ?? "")
            }
            .sensoryFeedback(.error, trigger: opener.failures) { _, _ in model.panelLayout == layout }
    }
}

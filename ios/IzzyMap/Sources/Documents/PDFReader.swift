import IzzyKit
import PDFKit
import SwiftUI

/// A document opened from the device: PDFKit, full screen, at its page
/// (top of the page just under the bar), with native zoom. The title is the
/// community or tree in New York with the plant names italic, the page
/// ("Page 12 of 48") under it. Escape (hardware keyboard) closes it — the
/// first step of the window's Escape chain (`AppModel.escapeStep`). A
/// stored file that doesn't open says so and offers to download it again.
struct PDFReader: View {
    let opener: DocumentOpener
    let reading: DocumentOpener.Reading
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var broken = false
    @State private var current = 0
    @State private var count = 0

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFKitView(document: document, startPage: reading.page, current: $current)
                        .ignoresSafeArea(edges: .bottom)
                } else if broken {
                    ContentUnavailableView {
                        Label("This document doesn’t open", systemImage: "doc.questionmark")
                    } description: {
                        Text("The copy on this \(DeviceNoun.current) is damaged or incomplete.")
                            .foregroundStyle(DesignColor.secondaryInk)
                    } actions: {
                        Button("Download Again") { opener.downloadAgain() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("reader-download-again")
                    }
                    .accessibilityIdentifier("reader-broken")
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("reader-close")
                }
                ToolbarItem(placement: .principal) { header }
            }
        }
        .task(id: reading.url) { await load() }
        .onChange(of: current) { _, page in
            // the host re-presents at this page after a layout switch
            if opener.reading?.doc == reading.doc { opener.reading?.page = page }
        }
        .accessibilityIdentifier("pdf-reader")
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text(BotanicalNames.attributed(reading.doc.title))
                .font(.headline)
                .fontDesign(.serif)
                .lineLimit(1)
                // a community name fits the 16e's bar a size smaller
                // before it is cut in the middle
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if count > 0 {
                Text("Page \(current + 1) of \(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
                    .accessibilityIdentifier("reader-page")
            }
        }
    }

    /// A file that won't open (or has no pages) is "broken", never a blank
    /// screen. (PDFDocument reads lazily: opening is the cross-reference
    /// table, not the pages.)
    private func load() async {
        let parsed = PDFDocument(url: reading.url).flatMap { $0.pageCount > 0 ? $0 : nil }
        document = parsed
        broken = parsed == nil
        if let parsed {
            count = parsed.pageCount
            current = min(max(0, reading.page), parsed.pageCount - 1)
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let startPage: Int
    @Binding var current: Int

    func makeUIView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .systemGroupedBackground
        view.pageShadowsEnabled = true
        view.document = document
        let binding = $current
        view.onPage = { binding.wrappedValue = $0 }
        let index = min(max(0, startPage), document.pageCount - 1)
        // after the first layout: going earlier lands on page 1
        DispatchQueue.main.async { view.open(at: index) }
        return view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {}
}

/// PDFView that keeps the reader's page: it reports page changes only once
/// it has been put at its start page (the first layout reports page 1),
/// and a resize (rotation, a Split View change, the window moving between
/// layouts) puts the page the reader was on back at the top instead of
/// wherever PDFKit's relayout scrolled to.
final class ReaderPDFView: PDFView {
    var onPage: ((Int) -> Void)?
    private var page: Int?
    private var lastSize: CGSize = .zero
    private var relayingOut = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `index` with the page's top edge right under the bar (the
    /// destination is the page's top-left corner, not "go to page", which
    /// leaves it wherever the scroll position happens to put it).
    func open(at index: Int) {
        guard let document, let target = document.page(at: index) else { return }
        page = index
        let box = target.bounds(for: displayBox)
        go(to: PDFDestination(page: target, at: CGPoint(x: box.minX, y: box.maxY)))
        onPage?(index)
    }

    override func layoutSubviews() {
        let resized = lastSize != .zero && bounds.size != lastSize
        relayingOut = true
        super.layoutSubviews()
        relayingOut = false
        lastSize = bounds.size
        if resized, let page { open(at: page) }
    }

    @objc private func pageChanged() {
        guard !relayingOut, page != nil, let current = currentPage, let document else { return }
        let index = document.index(for: current)
        guard index != page else { return }
        page = index
        onPage?(index)
    }
}

/// A page rendered small, for a document button once the file is on the
/// device ("she sees she's opening the book at its page").
enum PDFThumbnail {
    static func render(url: URL, page: Int, size: CGSize) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url), document.pageCount > 0,
                  let p = document.page(at: min(max(0, page), document.pageCount - 1)) else { return nil }
            return p.thumbnail(of: size, for: .cropBox)
        }.value
    }
}

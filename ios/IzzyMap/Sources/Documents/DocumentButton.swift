import IzzyKit
import SwiftUI

/// "Read the description" (F2F) and "Open the data sheet" (tree card): a
/// button whose caption says where the document will come from, and —
/// once it is on the device — a thumbnail of the page it opens at.
/// A tap opens it from disk, else fetches it once and opens the reader if
/// the card is still selected. Fetch, reader and failure belong to the
/// window (`DocumentOpener`, in the environment), not to this view: a plant
/// sheet pushed over the card parks the button without cancelling its
/// fetch, and the reader stays up across a layout switch.
struct DocumentButton: View {
    let doc: DocumentRef
    let title: String
    let symbol: String
    /// Who publishes it ("From Forest to Fjaeldmark", "City of Hobart").
    let publisher: String
    var sheetsTotal: Int?

    /// The window's opener (WindowContent puts it in the environment);
    /// a stand-alone button (previews) falls back to its own, presented here.
    @Environment(DocumentOpener.self) private var windowOpener: DocumentOpener?
    @State private var ownOpener: DocumentOpener?
    @State private var local: URL?
    @State private var gone = false
    @State private var thumb: UIImage?
    @ScaledMetric(relativeTo: .body) private var thumbHeight = 64

    private var opener: DocumentOpener? { windowOpener ?? ownOpener }
    private var fetching: Bool { opener?.isFetching(doc) == true }

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .center, spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if fetching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DesignColor.inkSecondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier(doc.kind == .f2f ? "read-description" : "open-sheet")
        .accessibilityHint(caption)
        .task(id: Refresh(doc: doc, revision: opener?.revision ?? 0, fetching: fetching)) { await refresh() }
        .onAppear { if windowOpener == nil, ownOpener == nil { ownOpener = DocumentOpener() } }
        .modifier(OwnReader(opener: windowOpener == nil ? ownOpener : nil))
    }

    private struct Refresh: Hashable {
        let doc: DocumentRef
        let revision: Int
        let fetching: Bool
    }

    /// The page it opens at (on the device), else the symbol.
    @ViewBuilder private var preview: some View {
        if let thumb {
            Image(uiImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: thumbHeight)
                .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(DesignColor.ink)
                .frame(width: thumbHeight * 0.75, height: thumbHeight * 0.75)
                .accessibilityHidden(true)
        }
    }

    private var caption: String {
        let size = doc.sizeText.map { " · \($0)" } ?? ""
        if fetching { return "\(publisher)\(size) · fetching…" }
        if local != nil { return "\(publisher)\(size) · on this \(DeviceNoun.current)" }
        if gone { return "\(publisher) · not published any more — tap to check again" }
        return "\(publisher)\(size) · fetched and kept the first time — needs reception"
    }

    private func refresh() async {
        local = DocumentStore.shared.localURL(doc)
        gone = DocumentStore.shared.isGone(doc)
        guard let local else { thumb = nil; return }
        thumb = await PDFThumbnail.render(url: local, page: doc.page, size: CGSize(width: 96, height: 128))
    }

    private func tap() {
        opener?.open(doc, title: title, sheetsTotal: sheetsTotal)
    }
}

/// A button outside a window's opener presents its own reader.
private struct OwnReader: ViewModifier {
    let opener: DocumentOpener?

    func body(content: Content) -> some View {
        if let opener {
            content.fullScreenCover(item: Binding(get: { opener.reading }, set: { if $0 == nil { opener.closeReader() } })) {
                PDFReader(opener: opener, reading: $0)
            }
        } else {
            content
        }
    }
}

extension DocumentRef {
    /// "0.6 MB" for a sheet (one decimal: they run 0.1–7 MB).
    var sizeText: String? {
        if case let .sheet(_, _, bytes?) = self { return ExtrasText.megabytes(bytes) }
        return nil
    }
}

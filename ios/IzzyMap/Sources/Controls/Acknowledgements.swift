import IzzyKit
import SwiftUI
import UIKit

/// Acknowledgements: every third-party component the app distributes with
/// its full licence text (acknowledgements.json, pipeline/
/// build_acknowledgements.py — the texts are the upstream files, verbatim).
/// Reached from Map Credits and from Identify ▸ Model & training photos.
struct AcknowledgementsView: View {
    /// On a presentation's glass (Map Credits) rather than a plain screen.
    var onGlass = false
    @State private var doc: Acknowledgements?
    @State private var failed = false

    var body: some View {
        List {
            if let doc {
                Section {
                    ForEach(doc.components) { c in
                        NavigationLink {
                            AcknowledgementDetail(component: c)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).foregroundStyle(DesignColor.ink)
                                Text("\(c.licence) · \(c.role)")
                                    .font(.subheadline)
                                    .foregroundStyle(DesignColor.inkSecondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                        .accessibilityIdentifier("ack-\(c.id)")
                    }
                } header: {
                    header("Software and model")
                } footer: {
                    Text("IzzyMap uses these under the licences shown; each one’s full text is inside.")
                }
                .rows(onGlass)
                Section {
                    ForEach(doc.data, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.inkSecondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    header("Data")
                }
                .rows(onGlass)
            } else if failed {
                Text("The licence texts couldn’t be read from the app — reinstall IzzyMap.")
                    .foregroundStyle(DesignColor.inkSecondary)
            } else {
                ProgressView()
            }
        }
        .surface(onGlass)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard doc == nil else { return }
            do {
                doc = try await Task.detached(priority: .userInitiated) {
                    guard let data = BundledData.inBundle() else { throw CocoaError(.fileNoSuchFile) }
                    return try data.acknowledgements()
                }.value
            } catch {
                failed = true
            }
        }
        .accessibilityIdentifier("acknowledgements-screen")
    }

    private func header(_ title: String) -> some View {
        Text(title).panelHeader()
    }
}

private extension View {
    @ViewBuilder func rows(_ onGlass: Bool) -> some View {
        if onGlass { panelRows() } else { self }
    }

    @ViewBuilder func surface(_ onGlass: Bool) -> some View {
        if onGlass { panelListSurface() } else { self }
    }
}

/// One component: what it is, then its licence texts and citations in one
/// selectable, scrolling text view (MapLibre's notices are ~100 KB, and a
/// SwiftUI `Text` only selects as a whole on iOS).
private struct AcknowledgementDetail: View {
    let component: Acknowledgements.Component

    var body: some View {
        SelectableText(text: Self.attributed(component))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(component.name)
            .navigationBarTitleDisplayMode(.inline)
    }

    static func attributed(_ c: Acknowledgements.Component) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ s: String, _ style: UIFont.TextStyle, weight: UIFont.Weight = .regular, mono: Bool = false,
                 colour: UIColor = .label, after: CGFloat = 8, link: URL? = nil) {
            // the style's size at the default category, scaled by Dynamic Type
            // (adjustsFontForContentSizeCategory follows later changes)
            let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
            let raw = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
            let font = UIFontMetrics(forTextStyle: style).scaledFont(for: raw)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = after
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: para]
            if let link { attrs[.link] = link }
            out.append(NSAttributedString(string: s + "\n", attributes: attrs))
        }
        add(c.name, .title3, weight: .semibold, after: 2)
        add("\(c.version) · \(c.licence)", .subheadline, colour: .secondaryLabel, after: 2)
        add(c.url.absoluteString, .subheadline, after: 12, link: c.url)
        add(c.role, .body, after: 8)
        for note in c.notes { add(note, .subheadline, colour: .secondaryLabel, after: 6) }
        for t in c.texts {
            add("", .footnote, after: 4)
            add(t.title, .headline, weight: .semibold, after: 8)
            add(t.reflowed, .footnote, after: 8)
        }
        if !c.citations.isEmpty {
            add("", .footnote, after: 4)
            add("Citation", .headline, weight: .semibold, after: 4)
            add("The model’s authors ask that it be cited as:", .subheadline, colour: .secondaryLabel, after: 8)
            for cite in c.citations {
                add(cite.title, .subheadline, weight: .semibold, after: 4)
                add(cite.text, .caption1, mono: true, after: 12)
            }
        }
        return out
    }
}

/// A read-only, selectable, scrolling UITextView (links tappable).
private struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.attributedText = text
        view.accessibilityIdentifier = "ack-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != text { view.attributedText = text }
    }
}

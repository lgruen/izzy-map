import AuthenticationServices
import SwiftUI

/// Export (docs/PINS_PLAN.md §6): one sheet over the Pins screen — what is
/// exported (the project's swatch, name, counts), the one option (Include
/// photos, a checkmark row), the two destinations (Google Docs first when
/// the build has a client id, Share file…), then progress with Cancel, and
/// the result. Every failure offers the file. Escape closes it (PinsScreen
/// counts it as a level); closing stops a job under way.
struct PinExportSheet: View {
    let store: PinStore
    let target: PinExportTarget
    /// Bumped by Escape (PinsScreen): Cancel while working, else close.
    var escapeRequest = 0
    let close: () -> Void

    @State private var model: PinExportModel
    @State private var drive = GoogleDrive.shared
    /// The Share file button's frame in the actions' space: the share
    /// popover's arrow points at it (kept while the button is replaced by
    /// progress — the file is shared once it is back).
    @State private var shareFrame: CGRect?
    private static let actionsSpace = "export-actions"
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL

    init(store: PinStore, target: PinExportTarget, escapeRequest: Int = 0, close: @escaping () -> Void) {
        self.store = store
        self.target = target
        self.escapeRequest = escapeRequest
        self.close = close
        _model = State(initialValue: PinExportModel(container: store.container))
    }

    private var project: PinProject? { target.project.flatMap { store.project($0) } }
    /// The pins as they are now (re-read with the store).
    private var snapshot: PinExportSnapshot {
        _ = store.revision
        return PinExportSnapshot.make(project: project, pins: store.pins(in: project), only: target.pins)
    }

    var body: some View {
        let snapshot = snapshot
        NavigationStack {
            // plain sections on the sheet's own ground, as Storage
            PinsList {
                Section {
                    ExportSubject(store: store, project: project, isUnfiled: target.project == nil, snapshot: snapshot,
                                  of: target.pins == nil ? nil : store.pins(in: project).count)
                        .listRowSeparator(.hidden)
                }
                .panelRows()

                if snapshot.photoCount > 0 {
                    Section {
                        IncludePhotosRow(on: model.includePhotos, count: snapshot.photoCount) {
                            model.includePhotos.toggle()
                        }
                        .disabled(model.isWorking)
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Photos").panelHeader()
                    } footer: {
                        Text("Photos are made smaller (1,600 px on the long side), and their location and camera data are removed.")
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                    .panelRows()
                }

                Section {
                    actions(snapshot)
                        .padding(.vertical, 4)
                        // the share sheet's host (a popover on iPad, pointing
                        // at the Share file button) — one stable view
                        // whatever the phase shows
                        .background(ActivityPresenter(item: $model.shareRequest, anchor: shareFrame))
                        .coordinateSpace(.named(Self.actionsSpace))
                        .listRowSeparator(.hidden)
                } header: {
                    Text("Destination").panelHeader()
                } footer: {
                    footer
                }
                .panelRows()
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .uploaded = model.phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark", action: close)
                            .accessibilityIdentifier("export-done")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark", action: close)
                            .accessibilityIdentifier("export-close")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isWorking)
        .sensoryFeedback(trigger: model.phase) { _, new in
            switch new {
            case .uploaded: .success
            case .failed: .error
            default: nil
            }
        }
        .onDisappear { model.cancel() }
        .onChange(of: escapeRequest) { if model.escape() { close() } }
        #if DEBUG
        // screenshots: `-openPinsExportStart google|share` starts at once
        .task {
            switch UserDefaults.standard.string(forKey: "openPinsExportStart") {
            case "google": if let drive { google(snapshot, drive) }
            case "share": model.shareFile(snapshot)
            default: break
            }
        }
        #endif
        .accessibilityIdentifier("export-sheet")
    }

    // MARK: The destinations, progress, result

    @ViewBuilder
    private func actions(_ snapshot: PinExportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .idle:
                if let drive {
                    ExportCapsule(title: "Save to Google Docs", symbol: "doc.text", prominent: true) { google(snapshot, drive) }
                        .accessibilityIdentifier("export-google")
                    shareButton(snapshot, prominent: false)
                } else {
                    shareButton(snapshot, prominent: true)
                }
            case .signingIn:
                ExportProgress(title: "Signing in to Google…", detail: nil, fraction: nil, cancel: model.cancel)
            case let .building(done, total):
                // a bar only while photos count up; the text alone is one
                // step with nothing to measure — a spinner, never an empty bar
                ExportProgress(title: total > 1 && done < total - 1 ? "Preparing photos…" : "Writing the document…",
                               detail: total > 1 && done < total - 1 ? "\(done.formatted()) of \((total - 1).formatted())" : nil,
                               fraction: total > 1 ? Double(done) / Double(total) : nil, cancel: model.cancel)
            case let .uploading(fraction):
                ExportProgress(title: "Uploading to Google Drive…", detail: fraction.formatted(.percent.precision(.fractionLength(0))),
                               fraction: fraction, cancel: model.cancel)
            case let .uploaded(doc):
                ExportOutcome(symbol: StateSymbol.onDevice, title: "Saved to Google Drive",
                              message: "A new Google Doc, “\(PinExport.fileName(stem: snapshot.fileStem).replacingOccurrences(of: ".docx", with: ""))”.")
                    .accessibilityIdentifier("export-uploaded")
                ExportCapsule(title: "Open in Google Docs", symbol: "arrow.up.forward.app", prominent: true) { openURL(doc.webViewLink) }
                    .accessibilityIdentifier("export-open-doc")
                shareButton(snapshot, prominent: false)
            case let .failed(failure):
                ExportOutcome(symbol: "exclamationmark.triangle", title: failure.title, message: failure.message)
                    .accessibilityIdentifier("export-failed")
                if failure.offersFile {
                    shareButton(snapshot, prominent: true, title: "Share file instead…")
                }
                if let retry = failure.retryTitle {
                    ExportCapsule(title: retry, symbol: failure.needsSignIn ? "person.crop.circle" : "arrow.clockwise",
                                  prominent: !failure.offersFile) {
                        if model.destination == .google, let drive { google(snapshot, drive) } else { model.shareFile(snapshot) }
                    }
                    .accessibilityIdentifier("export-retry")
                } else {
                    ExportCapsule(title: "Back", symbol: "chevron.backward", prominent: false) { model.reset() }
                        .accessibilityIdentifier("export-back")
                }
            }
            if !model.isWorking, let note = model.omitted.sentence {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export-omitted")
            }
        }
        .animation(.snappy, value: model.phase)
    }

    private func shareButton(_ snapshot: PinExportSnapshot, prominent: Bool, title: String = "Share file…") -> some View {
        ExportCapsule(title: title, symbol: "square.and.arrow.up", prominent: prominent) { model.shareFile(snapshot) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.actionsSpace)) } action: { shareFrame = $0 }
            .accessibilityIdentifier("export-share")
    }

    private func google(_ snapshot: PinExportSnapshot, _ drive: GoogleDrive) {
        let session = webAuthenticationSession
        model.exportToGoogle(snapshot, drive: drive, projectKey: target.projectKey) { url, scheme in
            // her browser session (not ephemeral): signed in to Google
            // already, she only confirms
            try await session.authenticate(using: url, callback: .customScheme(scheme), preferredBrowserSession: .shared,
                                           additionalHeaderFields: [:])
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let drive, !model.isWorking {
            VStack(alignment: .leading, spacing: 6) {
                if case .uploaded = model.phase {
                    EmptyView()
                } else if let last = drive.lastLinks[target.projectKey] {
                    Button {
                        openURL(last.webViewLink)
                    } label: {
                        Text("Open the last export in Google Docs")
                            .underline()
                            .foregroundStyle(DesignColor.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("export-last-doc")
                }
                Text(drive.isConnected
                     ? "Google Docs: each export is a new Doc in your Drive. Signed in to Google."
                     : "Google Docs: each export is a new Doc in your Drive. The first time, you sign in to Google; IzzyMap can then see only the files it makes.")
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if drive.isConnected {
                    Button("Sign out of Google") {
                        Task { await drive.disconnect() }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
                    .contentShape(.rect)
                    .accessibilityIdentifier("export-disconnect")
                }
            }
        } else if drive == nil, !model.isWorking {
            Text("A Word document: it opens in Pages, Word and Google Docs.")
                .foregroundStyle(DesignColor.secondaryInk)
        }
    }
}

// MARK: - Pieces

/// The project's swatch (or Unfiled's tray), its name and what goes out.
private struct ExportSubject: View {
    let store: PinStore
    let project: PinProject?
    let isUnfiled: Bool
    let snapshot: PinExportSnapshot
    /// A selection: how many pins the project has.
    let of: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let project {
                KeyBox(hex: PinColour.hex(forName: project.colour), opacity: 1, width: 44, height: 44)
            } else {
                GlyphSwatch(symbol: "tray", side: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(project.map { PinText.projectName($0.name) } ?? "Unfiled")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
                    .accessibilityIdentifier("export-counts")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// "8 pins · 9 photos · 3–24 Nov"; a selection: "3 of 12 pins · …".
    private var status: String {
        let n = snapshot.pins.count
        var parts = [of.map { "\(n.formatted()) of \($0.formatted()) \($0 == 1 ? "pin" : "pins")" } ?? PinText.count(n)]
        if snapshot.photoCount > 0 { parts.append(PinText.photoCount(snapshot.photoCount)) }
        if let range = PinText.dateRange(snapshot.pins.map(\.createdAt)) { parts.append(range) }
        return parts.joined(separator: " · ")
    }
}

/// "Include photos": a checkmark row (no toggles, DESIGN.md §2).
private struct IncludePhotosRow: View {
    let on: Bool
    let count: Int
    let toggle: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
                    .frame(width: 28)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include photos").foregroundStyle(DesignColor.ink)
                    Text(on ? "\(PinText.photoCount(count)), two across" : "Text only")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? DesignColor.ink : DesignColor.secondaryInk)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("export-photos")
    }
}

/// A destination: the ink capsule (the sheet's point) or its quiet twin.
struct ExportCapsule: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(prominent ? Color(uiColor: .systemBackground) : DesignColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? AnyShapeStyle(DesignColor.ink) : AnyShapeStyle(DesignColor.ink.opacity(0.08)), in: .capsule)
                .overlay {
                    if !prominent { Capsule().strokeBorder(DesignColor.ink.opacity(0.35), lineWidth: 0.5) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// A job under way: what it's doing, how far, Cancel.
private struct ExportProgress: View {
    let title: String
    let detail: String?
    /// nil: indeterminate (signing in).
    let fraction: Double?
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                // nothing to measure yet (signing in, one writing step): a
                // small spinner by the words, no empty track
                if fraction == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DesignColor.ink)
                        .accessibilityIdentifier("export-progress")
                }
                Text(title)
                    .foregroundStyle(DesignColor.ink)
                    .accessibilityIdentifier("export-progress-title")
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                }
            }
            if let fraction {
                RowProgress(fraction: fraction, identifier: "export-progress")
            }
            HStack {
                Spacer()
                GetButton(title: "Cancel", action: cancel)
                    .accessibilityIdentifier("export-cancel")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A result: the state's glyph, a headline and what to do next.
private struct ExportOutcome: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(DesignColor.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DesignColor.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Share sheet

/// Presents the system share sheet for `item` from the view it sits
/// behind: a popover pointing at it on iPad, a sheet on iPhone. UIKit's
/// `UIActivityViewController`, because the file exists only after the tap
/// (a `ShareLink` needs its item up front). Clears `item` when it closes.
struct ActivityPresenter: UIViewRepresentable {
    @Binding var item: ShareRequest?
    /// Where in this view the popover points (the button that asked);
    /// nil: the whole view.
    var anchor: CGRect? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var presented: UUID?
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let request = item, context.coordinator.presented != request.id else { return }
        context.coordinator.presented = request.id
        let url = request.url
        let anchor = anchor
        let binding = $item
        let coordinator = context.coordinator
        // after this layout pass, so the anchor is in its window
        Task { @MainActor in
            guard var host = view.owningViewController else {
                coordinator.presented = nil
                binding.wrappedValue = nil
                return
            }
            while let next = host.presentedViewController, !next.isBeingDismissed { host = next }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = anchor.flatMap { view.bounds.intersects($0) ? $0 : nil } ?? view.bounds
            activity.completionWithItemsHandler = { _, _, _, _ in
                coordinator.presented = nil
                binding.wrappedValue = nil
            }
            host.present(activity, animated: true)
            // refused (the host was busy presenting): no completion will
            // come — clear the request so the next tap tries again
            if activity.presentingViewController == nil {
                coordinator.presented = nil
                binding.wrappedValue = nil
            }
        }
    }
}

private extension UIView {
    /// The view controller whose view holds this one (the sheet's host).
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}

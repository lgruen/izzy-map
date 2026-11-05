import IzzyKit
import SwiftUI

/// The installed model's identity: pipeline.json `model` (build_ship.py v2):
/// run id, scripts' git commit, build date, classes, a parameter summary.
nonisolated struct PlantIDModelIdentity: Decodable, Sendable {
    var id: String
    var git: String?
    var git_clean: Bool?
    var built: String?
    var classes: Int?
    var summary: String?

    private struct Pipeline: Decodable { var model: PlantIDModelIdentity? }

    static func load(_ dir: URL) -> PlantIDModelIdentity? {
        (try? JSONDecoder().decode(Pipeline.self, from: Data(contentsOf: dir.appending(path: PlantIDFiles.pipeline))))?.model
    }

    /// "final-cb50-s1 · git 85d6f486d6 · 2026-11-05 · 22,122 classes"
    var line: String {
        [id, git.map { "git \($0)\(git_clean == false ? "+" : "")" }, built,
         classes.map { "\($0.formatted()) classes" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// credits.json (pipeline/plantid/build_ship.py `v2_credits`): every
/// creator whose photos trained the model (iNaturalist observers, ALA
/// providers incl. APII photographers, Wikimedia Commons authors).
nonisolated struct PlantIDCredits: Decodable, Sendable {
    struct Observer: Decodable, Sendable, Identifiable {
        var login: String
        var name: String?
        var photos: Int
        var licences: [String: Int]
        /// "ala" / "commons"; nil = iNaturalist.
        var source: String?
        var id: String { "\(source ?? "inat")/\(login)" }
    }

    struct Source: Decodable, Sendable {
        var photos: Int
        var credited: Int?
    }

    var about: String?
    var photos: Int
    var licences: [String: Int]
    var sources: [String: Source]?
    var observers: [Observer]

    static func load(_ dir: URL) throws -> PlantIDCredits {
        try JSONDecoder().decode(PlantIDCredits.self, from: Data(contentsOf: dir.appending(path: PlantIDFiles.credits)))
    }

    /// "CC BY-NC" from iNaturalist's "CC-BY-NC".
    static func licence(_ code: String) -> String {
        code == "CC0" ? "CC0" : code.replacingOccurrences(of: "CC-", with: "CC ")
    }
}

/// "Model & training photos": the model, the training photos' licences
/// and every observer, searchable (CC BY / BY-NC attribution, LICENSING.md).
struct PlantIDCreditsView: View {
    let source: PlantIDSource?
    @State private var credits: PlantIDCredits?
    @State private var failed = false
    @State private var query = ""
    @State private var identity: PlantIDModelIdentity?

    private var observers: [PlantIDCredits.Observer] {
        guard let credits else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return credits.observers }
        return credits.observers.filter { $0.login.lowercased().contains(q) || ($0.name ?? "").lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("plant-id-credits-headline")
                    Text("The image model is BioCLIP 2.5 (Imageomics Institute), run on this device. IzzyMap’s classifier for Australia’s plants was trained on photos from the iNaturalist Open Dataset, the Atlas of Living Australia (including the Australian Plant Image Index, Australian National Botanic Gardens) and Wikimedia Commons; each photo © its creator under the licence shown. Non-commercial licences bind IzzyMap to non-commercial use, which it is.")
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if let credits {
                        Text(credits.licences.sorted { $0.value > $1.value }
                            .map { "\($0.value.formatted()) \(PlantIDCredits.licence($0.key))" }.joined(separator: " · "))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                    if let sources = credits?.sources {
                        Text(sourceLine(sources))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Location ranking uses iNaturalist and Atlas of Living Australia records across Australia. Photo pages: inaturalist.org/photos/<id>; the per-photo list ships with the model (credits-photos.tsv.gz).")
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if let identity {
                        Text("Model \(identity.line)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("plant-id-model-identity")
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                .accessibilityIdentifier("acknowledgements-link")
            } footer: {
                Text("BioCLIP 2.5’s MIT licence and citation, and the app’s other software licences.")
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            if credits != nil {
                Section {
                    ForEach(observers) { o in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.name.flatMap { $0.isEmpty ? nil : $0 } ?? o.login)
                                    .font(.body)
                                    .foregroundStyle(DesignColor.ink)
                                if let name = o.name, !name.isEmpty {
                                    Text(o.login)
                                        .font(.caption)
                                        .foregroundStyle(DesignColor.secondaryInk)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(o.photos == 1 ? "1 photo" : "\(o.photos.formatted()) photos")
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundStyle(DesignColor.ink)
                                Text(o.licences.keys.sorted().map(PlantIDCredits.licence).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(DesignColor.secondaryInk)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Observers").foregroundStyle(DesignColor.secondaryInk)
                }
            } else if failed {
                Text("The full list of observers comes with the identification model.")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Model & Training Photos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find an observer")
        .task {
            guard credits == nil, case let .files(dir) = source else { failed = true; return }
            identity = await Task.detached(priority: .utility) { PlantIDModelIdentity.load(dir) }.value
            do { credits = try await Task.detached(priority: .userInitiated) { try PlantIDCredits.load(dir) }.value } catch {
                failed = true
            }
        }
        .accessibilityIdentifier("plant-id-credits-screen")
    }

    private func sourceLine(_ s: [String: PlantIDCredits.Source]) -> String {
        [("inat", "iNaturalist"), ("ala", "ALA"), ("commons", "Wikimedia Commons")].compactMap { key, name in
            s[key].map { "\(name) \($0.photos.formatted()) photos" + ($0.credited.map { " by \($0.formatted())" } ?? "") }
        }.joined(separator: " · ")
    }

    private var headline: String {
        guard let credits else { return "Identification by BioCLIP 2.5, trained on photos of Australia’s plants" }
        return "Identification by BioCLIP 2.5, trained on \(credits.photos.formatted()) photos by \(credits.observers.count.formatted()) photographers"
    }
}

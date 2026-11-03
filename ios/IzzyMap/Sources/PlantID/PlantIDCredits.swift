import SwiftUI

/// credits.json (pipeline/plantid/build_ship.py `build_credits`): every
/// observer whose iNaturalist photos trained the head and the kNN bank.
nonisolated struct PlantIDCredits: Decodable, Sendable {
    struct Observer: Decodable, Sendable, Identifiable {
        var login: String
        var name: String?
        var photos: Int
        var licences: [String: Int]
        var id: String { login }
    }

    var about: String?
    var photos: Int
    var licences: [String: Int]
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
                    Text("The image model is BioCLIP 2.5 (Imageomics Institute), run on this device. IzzyMap’s classifier and its comparison photos were trained for Tasmania’s plants on photos from the iNaturalist Open Dataset; each photo © its observer under the licence shown — CC0, CC BY or CC BY-NC (non-commercial, which IzzyMap is). Photos under ND or SA licences were left out.")
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let credits {
                        Text(credits.licences.sorted { $0.value > $1.value }
                            .map { "\($0.value.formatted()) \(PlantIDCredits.licence($0.key))" }.joined(separator: " · "))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.inkSecondary)
                    }
                    Text("Location ranking uses iNaturalist research-grade records in Tasmania. Photo pages: inaturalist.org/photos/<id>; the per-photo list ships with the model (credits-photos.tsv.gz).")
                        .font(.footnote)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            }
            if credits != nil {
                Section("Observers") {
                    ForEach(observers) { o in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.name.flatMap { $0.isEmpty ? nil : $0 } ?? o.login)
                                    .font(.body)
                                    .foregroundStyle(DesignColor.ink)
                                if let name = o.name, !name.isEmpty {
                                    Text(o.login)
                                        .font(.caption)
                                        .foregroundStyle(DesignColor.inkSecondary)
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
                                    .foregroundStyle(DesignColor.inkSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if failed {
                Text("The full list of observers comes with the identification model.")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.inkSecondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Model & Training Photos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find an observer")
        .task {
            guard credits == nil, case let .files(dir) = source else { failed = true; return }
            do { credits = try await Task.detached(priority: .userInitiated) { try PlantIDCredits.load(dir) }.value } catch {
                failed = true
            }
        }
        .accessibilityIdentifier("plant-id-credits-screen")
    }

    private var headline: String {
        guard let credits else { return "Identification by BioCLIP 2.5, trained on iNaturalist photos" }
        return "Identification by BioCLIP 2.5, trained on iNaturalist photos by \(credits.observers.count.formatted()) observers"
    }
}

import PhotosUI
import SwiftUI

struct ContentView: View {
    @ObservedObject var runner: Runner
    @State private var pick: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Plant ID: can this phone run the model?").font(.title2.bold())
                Text("This app tests whether the most accurate plant-identification model (BioCLIP 2.5, 1.26 GB, already inside the app) runs on this phone. It tries the model three ways and can take a few minutes. Keep the app open and the screen on until it says Done.")
                Text("If the app closes by itself, that is a result too: open it again and press Start test again. When it says Done, press Copy results.").bold()

                if !runner.previous.isEmpty {
                    GroupBox(runner.previous.count == 1 ? "Previous attempt" : "Previous attempts") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(runner.previous, id: \.self) { Text($0) }
                            Text("Its details are included when you press Copy results.").font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button(runner.state == .done ? "Run the test again" : "Start test") { runner.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(runner.state == .running || runner.ownBusy)

                ForEach(runner.steps) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.status).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            if !s.detail.isEmpty {
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if runner.state == .done {
                    Text("Done. Now press Copy results below and send them to Leo.").bold()
                }

                if !runner.verdict.isEmpty {
                    GroupBox("Result") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(runner.verdict).bold()
                            ForEach(runner.lines, id: \.self) { Text($0).font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Send the results") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Copy results") { runner.copy() }.buttonStyle(.bordered)
                            ShareLink("Share…", item: runner.reportText())
                        }
                        Text(runner.copied ? "Copied. Now paste it into a message to Leo." : "Nothing is sent anywhere by itself.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Try your own photo (optional)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("After the test, pick a photo of a plant. The answer uses the photo only (the real app would also use your location).")
                            .font(.callout)
                        PhotosPicker("Choose a photo", selection: $pick, matching: .images)
                            .disabled(runner.state != .done || runner.ownBusy || runner.crashedAll)
                        if !runner.ownResult.isEmpty {
                            Text(runner.ownResult).font(.callout.monospaced())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

            }
            .padding()
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                runner.classifyOwn(try? await item.loadTransferable(type: Data.self))
                pick = nil
            }
        }
        .onAppear {
            if CommandLine.arguments.contains("-autorun") { runner.start() }
        }
    }
}

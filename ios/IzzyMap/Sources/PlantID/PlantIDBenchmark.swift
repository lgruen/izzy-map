import CoreML
import Foundation
import Observation
import os
import SwiftUI
import UIKit

/// "Benchmark identifier load" (Diagnostics; only ever on her tap, after a
/// confirmation): the encoder loaded from {the pack's folder, the app's
/// copy} × {CPU+ANE, CPU+GPU, all, CPU only}, one model at a time — load
/// time, a first (warm-up) and a second prediction, the app's memory
/// footprint with it loaded. Each row is saved as it completes, so a run
/// the system ends (memory) still shows how far it got; the run before is
/// kept too, to compare across relaunches (does a cache kick in?).
nonisolated enum PlantIDBenchmark {
    static var units: [MLComputeUnits] {
        #if DEBUG
        // `-plantIDBenchmarkUnits 0` (MLComputeUnits raw values, comma-separated):
        // a shorter run in the simulator, where every load is CPU and ~20 s
        if let raw = UserDefaults.standard.string(forKey: "plantIDBenchmarkUnits"), !raw.isEmpty {
            return raw.split(separator: ",").compactMap { Int($0).flatMap(MLComputeUnits.init(rawValue:)) }
        }
        #endif
        return [.cpuAndNeuralEngine, .cpuAndGPU, .all, .cpuOnly]
    }

    /// Runs every combination; `report` gets the text so far after each step.
    static func run(dir: URL, report: @escaping @Sendable (String, _ during: String?) async -> Void) async {
        let info = Bundle.main.infoDictionary ?? [:]
        let started = ContinuousClock.now
        var lines = [
            "Identifier load benchmark · IzzyMap \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
                + " · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Date.now.formatted(.iso8601))",
            "model: \(PlantIDModelIdentity.load(dir)?.line ?? "?")",
            "app running for \(processAge().map { "\($0) s" } ?? "?") · footprint before \(MemoryUse.footprintMB().map { "\($0) MB" } ?? "?")",
        ]
        let pack = dir.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
        await report(lines.joined(separator: "\n"), "making the app copy")
        let placed = await PlantIDModelCopy.place(dir)
        lines.append("app copy: \(placed.location == .appCopy ? placed.note : "none — \(placed.note)")")
        lines.append("")
        lines.append("location  units     load ms  1st pred  2nd pred  footprint")
        var locations: [(String, URL)] = [("pack", pack)]
        if placed.location == .appCopy { locations.append(("app copy", placed.url)) }
        let second = (0 ..< CoreMLPlantEncoder.blank.count).map { Float(($0 % 97)) / 97 - 0.5 }
        for (place, url) in locations {
            for units in units {
                let name = CoreMLPlantEncoder.name(units)
                let label = "\(place.padding(toLength: 9, withPad: " ", startingAt: 0)) \(name.padding(toLength: 9, withPad: " ", startingAt: 0))"
                await report(lines.joined(separator: "\n"), "\(place) · \(name)")
                lines.append(label + " " + (await measure(url, units, second)))
                await report(lines.joined(separator: "\n"), nil)
                // the model is gone (released in `measure`); let memory settle
                try? await Task.sleep(for: .seconds(1))
            }
        }
        lines.append("")
        lines.append("footprint after release: \(MemoryUse.footprintMB().map { "\($0) MB" } ?? "?") · total \(Int((started.duration(to: .now) / .seconds(1)).rounded())) s")
        await report(lines.joined(separator: "\n"), nil)
    }

    /// One combination; the model is released before this returns.
    private static func measure(_ url: URL, _ units: MLComputeUnits, _ second: [Float]) async -> String {
        func ms(_ d: Duration) -> String { "\(Int((d / .milliseconds(1)).rounded()))" }
        func col(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
        let t0 = ContinuousClock.now
        let encoder: CoreMLPlantEncoder
        do { encoder = try await CoreMLPlantEncoder.load(url, units: units) } catch {
            return "load failed after \(ms(t0.duration(to: .now))) ms: \(error.localizedDescription)"
        }
        let load = t0.duration(to: .now)
        let t1 = ContinuousClock.now
        do { _ = try await encoder.embedding(CoreMLPlantEncoder.blank) } catch {
            return col(ms(load), 7) + "  prediction failed: \(error.localizedDescription)"
        }
        let p1 = t1.duration(to: .now)
        let t2 = ContinuousClock.now
        _ = try? await encoder.embedding(second)
        let p2 = t2.duration(to: .now)
        let footprint = MemoryUse.footprintMB().map { "\($0) MB" } ?? "?"
        return col(ms(load), 7) + col(ms(p1), 10) + col(ms(p2), 10) + col(footprint, 11)
    }

    /// Seconds since this process started, for "app running for n s" (a
    /// fresh launch vs one that has loaded the model before).
    static func processAge() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int(Date.now.timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6))
    }
}

/// Runs the benchmark beyond the Diagnostics screen's lifetime and keeps
/// its text (UserDefaults: this run, the one before).
@MainActor @Observable
final class PlantIDBenchmarkRunner {
    static let shared = PlantIDBenchmarkRunner()

    private(set) var running = false
    /// What is being measured now.
    private(set) var during: String?
    private(set) var text: String?
    private(set) var previous: String?
    /// Why it didn't start.
    private(set) var refusal: String?

    private static let textKey = "plantIDBenchmarkText"
    private static let duringKey = "plantIDBenchmarkDuring"
    private static let previousKey = "plantIDBenchmarkPrevious"

    private init() {
        let d = UserDefaults.standard
        text = d.string(forKey: Self.textKey)
        previous = d.string(forKey: Self.previousKey)
        // a run this process didn't finish: the app was stopped mid-way
        if let stopped = d.string(forKey: Self.duringKey), let t = text {
            text = t + "\n(stopped during \(stopped) — the app ended there, probably for memory)"
            d.set(text, forKey: Self.textKey)
            d.removeObject(forKey: Self.duringKey)
        }
    }

    func start(dir: URL) {
        guard !running else { return }
        refusal = nil
        if PlantIDEngine.loadsInFlight.withLock({ $0 }) > 0 {
            refusal = "The identifier is loading — try again once it has loaded."
            return
        }
        running = true
        PlantIDEngineKeeper.shared.releaseAll()
        let d = UserDefaults.standard
        if let text {
            previous = text
            d.set(text, forKey: Self.previousKey)
        }
        text = nil
        Task.detached(priority: .userInitiated) {
            // the released engines' memory goes first
            try? await Task.sleep(for: .seconds(1))
            await PlantIDBenchmark.run(dir: dir) { text, during in
                await MainActor.run {
                    PlantIDBenchmarkRunner.shared.update(text, during: during)
                }
            }
            await MainActor.run { PlantIDBenchmarkRunner.shared.finish() }
        }
    }

    private func update(_ text: String, during: String?) {
        self.text = text
        self.during = during
        let d = UserDefaults.standard
        d.set(text, forKey: Self.textKey)
        if let during { d.set(during, forKey: Self.duringKey) } else { d.removeObject(forKey: Self.duringKey) }
    }

    private func finish() {
        running = false
        during = nil
        UserDefaults.standard.removeObject(forKey: Self.duringKey)
    }
}

/// The Diagnostics section: the button (with a confirmation), progress,
/// the results to copy.
struct PlantIDBenchmarkSection: View {
    let dir: URL
    @State private var runner = PlantIDBenchmarkRunner.shared
    @State private var confirming = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(runner.running ? "Benchmarking…" : "Benchmark identifier load", systemImage: "stopwatch") {
                confirming = true
            }
            .disabled(runner.running)
            .accessibilityIdentifier("diagnostics-benchmark")
            .confirmationDialog("Benchmark the identifier?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Run Benchmark") { runner.start(dir: dir) }
                    .accessibilityIdentifier("diagnostics-benchmark-run")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Loads the identification model eight times (pack and app copy × four compute-unit settings): several minutes, up to about 2 GB of memory. Keep IzzyMap open until it's done.")
            }
            if let refusal = runner.refusal {
                Text(refusal).font(.footnote).foregroundStyle(DesignColor.secondaryInk)
            }
            if let during = runner.during {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Measuring \(during)…").font(.footnote).foregroundStyle(DesignColor.secondaryInk)
                }
            }
            if let text = runner.text {
                Text(text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignColor.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("diagnostics-benchmark-text")
                Button(copied ? "Copied" : "Copy Benchmark", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = [text, runner.previous.map { "\nPrevious run:\n\($0)" }].compactMap { $0 }.joined(separator: "\n")
                    copied = true
                }
                .font(.footnote)
                .disabled(runner.running)
            }
            if let previous = runner.previous {
                DisclosureGroup("Previous run") {
                    Text(previous)
                        .font(.caption2.monospaced())
                        .foregroundStyle(DesignColor.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: runner.text) { _, _ in copied = false }
    }
}

import Accelerate
import CoreML
import Foundation
import os
import UIKit

// The test: load BioCLIP 2.5 (Core ML, fp16 weights) with each compute-unit
// choice, time it, measure the app's memory against what iOS still allows,
// and check its embeddings for three CC0 photos against the laptop's
// (PyTorch fp32) — the same references as the Safari test page.
// A step marker written to a file at every step survives an iOS memory kill,
// so the next launch reports where the previous attempt stopped.

struct TestInfo: Decodable {
    struct Input: Decodable { let size: Int; let mean: [Float]; let std: [Float] }
    struct Sample: Decodable { let photo_id: Int; let species: String; let top5: [[Double]]; let embedding: [Float] }
    let model: String
    let hf: String
    let input: Input
    let samples: [Sample]
}

struct Labels: Decodable { let names: [String]; let families: [String] }

/// The bundled test data (everything but the model), loaded once.
final class TestData: @unchecked Sendable {
    let info: TestInfo
    let names: [String]
    let text: [Float]  // count × dim, L2-normalised rows
    let dim: Int
    let inputs: [[Float]]  // the samples' preprocessed 1×3×224×224 tensors

    init() throws {
        guard let dir = Bundle.main.url(forResource: "data", withExtension: nil) else {
            throw TestError("the test data is missing from the app")
        }
        info = try JSONDecoder().decode(TestInfo.self, from: Data(contentsOf: dir.appendingPathComponent("test.json")))
        names = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: dir.appendingPathComponent("labels.json"))).names
        text = halfToFloat(try Data(contentsOf: dir.appendingPathComponent("text-f16.bin")))
        dim = text.count / names.count
        guard dim * names.count == text.count else { throw TestError("text vectors don't match the labels") }
        let x = halfToFloat(try Data(contentsOf: dir.appendingPathComponent("samples-f16.bin")))
        let n = 3 * info.input.size * info.input.size
        inputs = stride(from: 0, to: x.count, by: n).map { Array(x[$0 ..< $0 + n]) }
        guard inputs.count == info.samples.count else { throw TestError("sample tensors don't match test.json") }
    }

    /// Cosine of a unit vector with every species' text vector.
    func scores(_ u: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: names.count)
        vDSP_mmul(text, 1, u, 1, &out, 1, vDSP_Length(names.count), 1, vDSP_Length(dim))
        return out
    }
}

struct TestError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

func halfToFloat(_ d: Data) -> [Float] {
    let n = d.count / 2
    var out = [Float](repeating: 0, count: n)
    d.withUnsafeBytes { raw in
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1,
                                width: vImagePixelCount(n), rowBytes: n * 2)
        out.withUnsafeMutableBytes { o in
            var dst = vImage_Buffer(data: o.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
            _ = vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
        }
    }
    return out
}

/// The app's memory as iOS counts it (phys_footprint, the number jetsam
/// kills on) and how much more iOS would let it use.
struct Mem {
    let footprint: UInt64
    let available: UInt64?

    static func now() -> Mem {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var avail: UInt64? = nil
        #if os(iOS) && !targetEnvironment(macCatalyst)
        avail = UInt64(os_proc_available_memory())
        #endif
        return Mem(footprint: kr == KERN_SUCCESS ? info.phys_footprint : 0, available: avail)
    }

    var text: String {
        var s = "app memory \(mb(footprint))"
        if let a = available { s += ", iOS allows \(mb(a)) more" }
        return s
    }
}

/// Samples memory every 25 ms on its own queue: the highest footprint and the
/// lowest allowance since the last reset. Model loading peaks briefly (the
/// Safari test died in such a peak), which point samples would miss.
final class MemWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var maxFoot: UInt64 = 0
    private var minAvail: UInt64 = .max
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "memwatch", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        let m = Mem.now()
        lock.lock()
        maxFoot = max(maxFoot, m.footprint)
        if let a = m.available { minAvail = min(minAvail, a) }
        lock.unlock()
    }

    func reset() {
        sample()
        lock.lock()
        let m = Mem.now()
        maxFoot = m.footprint
        minAvail = m.available ?? .max
        lock.unlock()
    }

    var peak: (foot: UInt64, minAvail: UInt64?) {
        sample()  // include right now (a fast load can end between ticks)
        lock.lock()
        defer { lock.unlock() }
        return (maxFoot, minAvail == .max ? nil : minAvail)
    }

    var text: String {
        let p = peak
        var s = "peak \(mb(p.foot))"
        if let a = p.minAvail { s += ", iOS allowed as little as \(mb(a)) more" }
        return s
    }
}

func mb(_ b: UInt64) -> String { "\(b / 1_000_000) MB" }
func secs(_ t: Double) -> String { t < 10 ? String(format: "%.2f s", t) : String(format: "%.0f s", t) }

struct Config {
    let key: String
    let label: String
    let units: MLComputeUnits
}

let CONFIGS = [
    Config(key: "all", label: "automatic (Neural Engine + GPU + CPU, what an app would use)", units: .all),
    Config(key: "ane", label: "Neural Engine only", units: .cpuAndNeuralEngine),
    Config(key: "gpu", label: "GPU only", units: .cpuAndGPU),
]

/// Where an attempt is, written atomically to a file at every step and every
/// half second, so an iOS kill leaves it behind for the next launch.
struct Marker: Codable {
    var step: String
    var blame: String  // compute choice a kill here counts against ("" = none)
    var stepStarted: Date
    var background: Bool
    var lines: [String]  // results so far, incl. the running choice's partial line
    var memory: String  // the memory watch during this step
}

struct Saved: Codable {
    var marker: Marker?
    var previous: [String] = []
    var crashed: [String: String] = [:]  // compute choice → step it was killed in
    var runs = 0
}

struct Step: Identifiable {
    let id = UUID()
    let name: String
    var status: String  // "…", "✓", "✗", "–"
    var detail: String
    let started = Date()
}

/// Runs work off the main thread (model loads and predictions block), inside
/// an autorelease pool so nothing Core ML autoreleases outlives the call.
func off<T>(_ f: @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try autoreleasepool { try f() } }.value
}

@MainActor
final class Runner: ObservableObject {
    enum State { case idle, running, done }

    @Published var state = State.idle
    @Published var steps: [Step] = []
    @Published var verdict = ""
    @Published var lines: [String] = []
    @Published var previous: [String] = []
    @Published var ownResult = ""
    @Published var ownBusy = false
    @Published var copied = false

    private var saved = Saved()
    private let file: URL
    private var data: TestData?
    private var ownModel: MLModel?
    private var background = false
    private var leftForeground = false  // during the current compute choice
    private var partial: String?
    private let watch = MemWatch()
    private let launchMem = Mem.now()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("plantid-test-v1.json")
        if let raw = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: raw) {
            saved = s
        }
        if let m = saved.marker {
            var s = "Stopped during “\(m.step)” (\(m.stepStarted.formatted(date: .abbreviated, time: .standard)))"
            if m.background {
                s += ". The app had left the screen, so iOS may simply have closed it."
            } else {
                s += ". iOS most likely shut the app down for using too much memory."
                if !m.blame.isEmpty { saved.crashed[m.blame] = m.step }
            }
            if !m.memory.isEmpty { s += " Memory in that step: \(m.memory)." }
            if !m.lines.isEmpty { s += "\nResults before that:\n" + m.lines.joined(separator: "\n") }
            saved.previous.append(s)
            saved.marker = nil
            persist()
        }
        previous = saved.previous
    }

    // MARK: markers

    private func persist() {
        if let raw = try? JSONEncoder().encode(saved) { try? raw.write(to: file, options: .atomic) }
    }

    private func mark(_ step: String, blame: String = "") {
        watch.reset()
        saved.marker = Marker(step: step, blame: blame, stepStarted: Date(), background: background,
                              lines: lines + (partial.map { [$0] } ?? []), memory: "")
        persist()
    }

    /// Refresh the marker's results and memory watch (every half second).
    private func touch() {
        guard saved.marker != nil else { return }
        saved.marker!.lines = lines + (partial.map { [$0] } ?? [])
        saved.marker!.memory = watch.text
        saved.marker!.background = background
        persist()
    }

    private func clearMarker() {
        saved.marker = nil
        persist()
    }

    func phaseChanged(background bg: Bool) {
        background = bg  // cleared again on return: only a kill while away counts as "away"
        if bg { leftForeground = true }
        touch()
    }

    // MARK: steps

    private func begin(_ name: String, blame: String = "") -> Int {
        steps.append(Step(name: name, status: "…", detail: ""))
        mark(name, blame: blame)
        return steps.count - 1
    }

    private func end(_ i: Int, _ detail: String, ok: Bool = true) {
        steps[i].status = ok ? "✓" : "✗"
        steps[i].detail = detail
    }

    /// While running: live seconds + memory on the current step, and the marker refreshed.
    private func ticker() {
        Task {
            while state == .running || ownBusy {
                if let i = steps.indices.last, steps[i].status == "…" {
                    steps[i].detail = "\(Int(Date().timeIntervalSince(steps[i].started))) s so far · \(Mem.now().text)"
                }
                touch()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func modelURL() throws -> URL {
        guard let u = Bundle.main.url(forResource: "PlantEncoder", withExtension: "mlmodelc") else {
            throw TestError("the model is missing from the app")
        }
        return u
    }

    nonisolated static func load(_ url: URL, _ units: MLComputeUnits) throws -> MLModel {
        let c = MLModelConfiguration()
        c.computeUnits = units
        return try MLModel(contentsOf: url, configuration: c)
    }

    /// Raw model output, L2-normalised.
    nonisolated static func embed(_ model: MLModel, _ x: [Float], size S: Int, dim: Int) throws -> [Float] {
        guard x.count == 3 * S * S else { throw TestError("input has the wrong size") }
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)], dataType: .float32)
        arr.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
            x.withUnsafeBufferPointer { s in p.baseAddress!.update(from: s.baseAddress!, count: x.count) }
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["pixel_values": MLFeatureValue(multiArray: arr)]))
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else { throw TestError("no embedding output") }
        guard e.count == dim else { throw TestError("the model returned \(e.count) numbers, expected \(dim)") }
        var v = (0 ..< e.count).map { Float(truncating: e[$0]) }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0, norm.isFinite else { throw TestError("the model returned \(norm.isFinite ? "zeros" : "NaN/inf")") }
        vDSP_vsdiv(v, 1, &norm, &v, 1, vDSP_Length(v.count))
        return v
    }

    // MARK: the test

    func start() {
        guard state != .running, !ownBusy else { return }
        state = .running
        steps = []
        lines = []
        partial = nil
        verdict = ""
        copied = false
        ownModel = nil  // never hold a second copy while the test loads models
        ownResult = ""
        saved.runs += 1
        persist()
        UIApplication.shared.isIdleTimerDisabled = true
        ticker()
        Task {
            await run()
            UIApplication.shared.isIdleTimerDisabled = false
            state = .done
            clearMarker()
            if CommandLine.arguments.contains("-autorun") { await autorunTail() }
        }
    }

    private func run() async {
        var i = begin("Read the test files")
        do {
            let t0 = Date()
            data = try await off { try TestData() }
            end(i, "\(secs(Date().timeIntervalSince(t0))) · \(Mem.now().text)")
        } catch {
            end(i, error.localizedDescription, ok: false)
            verdict = "✗ FAILED: \(error.localizedDescription)"
            return
        }
        var main: String?
        for cfg in CONFIGS {
            if let step = saved.crashed[cfg.key] {
                i = begin("Skipped: \(cfg.label)")
                steps[i].status = "–"
                steps[i].detail = "the app was shut down during “\(step)” last time"
                lines.append("\(cfg.key): skipped — the app was shut down during “\(step)” in an earlier attempt")
                if cfg.key == "all" {
                    main = "✗ With the automatic choice, the app was shut down during “\(step)” (most likely too much memory)."
                }
                continue
            }
            let r = await runConfig(cfg)
            if cfg.key == "all" { main = r }
        }
        verdict = main ?? ""
    }

    private func thermal() -> String {
        let t = ["nominal", "fair", "serious", "critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)]
        return "thermal \(t)" + (ProcessInfo.processInfo.isLowPowerModeEnabled ? " · Low Power Mode" : "")
    }

    /// One compute-unit choice: load, time, check. Never throws: a failure is a result.
    private func runConfig(_ cfg: Config) async -> String {
        guard let data else { return "" }
        let S = data.info.input.size, dim = data.dim
        var step = ""
        var i = 0
        leftForeground = background
        let before = Mem.now()
        do {
            let url = try modelURL()
            step = "Load the model: \(cfg.label)"
            i = begin(step, blame: cfg.key)
            var t0 = Date()
            var model: MLModel? = try await off { try Runner.load(url, cfg.units) }
            let load1 = Date().timeIntervalSince(t0)
            let mLoad = Mem.now()
            let loadWatch = watch.text
            end(i, "\(secs(load1)) · \(mLoad.text) · during load: \(loadWatch)")
            partial = "\(cfg.key): load \(secs(load1)) · before load \(mb(before.footprint)) · after load \(mLoad.text) · during load \(loadWatch)"

            step = "First run [\(cfg.key)]"
            i = begin(step, blame: cfg.key)
            let x0 = data.inputs[0]
            t0 = Date()
            _ = try await off { try Runner.embed(model!, x0, size: S, dim: dim) }
            let first = Date().timeIntervalSince(t0)
            end(i, secs(first))
            partial! += " · first run \(secs(first))"

            step = "Timing 5 more runs [\(cfg.key)]"
            i = begin(step, blame: cfg.key)
            var times: [Double] = []
            for _ in 0 ..< 5 {
                t0 = Date()
                _ = try await off { try Runner.embed(model!, x0, size: S, dim: dim) }
                times.append(Date().timeIntervalSince(t0))
            }
            let median = times.sorted()[2]
            end(i, "\(secs(median)) per photo (median)")
            partial! += " · then \(secs(median)) per photo"

            step = "Name the 3 test photos [\(cfg.key)]"
            i = begin(step, blame: cfg.key)
            var cosines: [Float] = []
            var same = 0, right = 0
            var named: [String] = []
            for (k, s) in data.info.samples.enumerated() {
                let x = data.inputs[k]
                let u = try await off { try Runner.embed(model!, x, size: S, dim: dim) }
                guard s.embedding.count == u.count else { throw TestError("reference embedding has the wrong size") }
                var c: Float = 0
                vDSP_dotpr(u, 1, s.embedding, 1, &c, vDSP_Length(u.count))
                cosines.append(c)
                let sc = data.scores(u)
                let top = sc.indices.max { sc[$0] < sc[$1] }!
                if top == Int(s.top5[0][0]) { same += 1 }
                if data.names[top] == s.species { right += 1 }
                named.append(data.names[top])
            }
            let minCos = cosines.min() ?? 0
            end(i, "named: \(named.joined(separator: ", ")) · min cosine to laptop \(String(format: "%.4f", minCos))")
            partial! += " · min cosine \(String(format: "%.4f", minCos)) · same answers as laptop \(same)/3"
                + " · right species \(right)/3 · after runs \(Mem.now().text) · \(thermal())"

            // A kill from here on isn't this choice's fault: the model loaded
            // and ran. The reload shows the model was freed (memory before it)
            // and how fast a cached load is (a lower bound for a later launch).
            model = nil
            try? await Task.sleep(nanoseconds: 300_000_000)
            let freed = Mem.now()
            step = "Load again (same session) [\(cfg.key)]"
            i = begin(step)
            t0 = Date()
            model = try await off { try Runner.load(url, cfg.units) }
            let load2 = Date().timeIntervalSince(t0)
            model = nil
            // Core ML frees a model shortly after the last reference goes:
            // wait for it, or the next choice loads beside it (seen on the Mac)
            for _ in 0 ..< 30 where Mem.now().footprint > freed.footprint + 200_000_000 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            end(i, "\(secs(load2)) · before it: \(freed.text)")
            partial! += " · after freeing \(mb(freed.footprint)) · reload \(secs(load2))"
            if leftForeground { partial! += " · (the app left the screen during this choice: times may be off)" }
            lines.append(partial!)
            partial = nil
            touch()
            let ok = minCos >= 0.99 && same == 3
            return ok
                ? "✓ It works on this phone: \(secs(median)) per photo; the model loaded in \(secs(load1))."
                : "✗ It runs but the answers are off (min cosine \(String(format: "%.4f", minCos)), same answers \(same)/3)."
        } catch {
            if i < steps.count, steps[i].status == "…" { end(i, error.localizedDescription, ok: false) }
            var line = (partial.map { $0 + " · " } ?? "\(cfg.key): ") + "FAILED at “\(step)”: \(error.localizedDescription)"
            if leftForeground { line += " (the app had left the screen: iOS stops apps using the GPU in the background, so this may not be the model's fault)" }
            lines.append(line)
            partial = nil
            touch()
            return "✗ FAILED at “\(step)”: \(error.localizedDescription)"
        }
    }

    // MARK: own photo

    func classifyOwn(_ photo: Data?) {
        guard state == .done, !ownBusy else { return }
        guard let photo else {
            ownResult = "Couldn't read that photo (if it's in iCloud, wait until it has downloaded and try again)."
            return
        }
        ownBusy = true
        ownResult = "Working…"
        ticker()
        Task {
            defer { ownBusy = false }
            do {
                guard let data else { throw TestError("run the test first") }
                if ownModel == nil {
                    mark("Own photo: load the model")  // blames no compute choice
                    let url = try modelURL()
                    ownModel = try await off { try Runner.load(url, .all) }
                }
                let model = ownModel!
                mark("Own photo")
                let inp = data.info.input, dim = data.dim
                var t0 = Date()
                let x = try await off { try Preprocess.tensor(photo, size: inp.size, mean: inp.mean, std: inp.std) }
                let prep = Date().timeIntervalSince(t0)
                t0 = Date()
                let u = try await off { try Runner.embed(model, x, size: inp.size, dim: dim) }
                let run = Date().timeIntervalSince(t0)
                let sc = data.scores(u)
                let top = Array(sc.indices.sorted { sc[$0] > sc[$1] }.prefix(5))
                // rough confidence: softmax at CLIP's logit scale (100), photo only, no location prior
                let best = sc[top[0]]
                let total = sc.reduce(Float(0)) { $0 + exp(100 * ($1 - best)) }
                ownResult = top.map { "\(data.names[$0])  \(Int((exp(100 * (sc[$0] - best)) / total * 100).rounded()))%" }
                    .joined(separator: "\n") + "\n(prepare \(secs(prep)) · model \(secs(run)))"
            } catch {
                ownResult = "Couldn't: \(error.localizedDescription)"
            }
            clearMarker()
        }
    }

    // MARK: report

    var crashedAll: Bool { saved.crashed["all"] != nil }

    func reportText() -> String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var s = ["Plant ID native test v2 (BioCLIP 2.5, Core ML, float16, increased-memory-limit entitlement)",
                 "device \(machine) · iOS \(UIDevice.current.systemVersion) · RAM \(mb(ProcessInfo.processInfo.physicalMemory))"
                     + " · at launch \(launchMem.text) · run #\(saved.runs) on this install · \(thermal())"]
        if !verdict.isEmpty { s.append(verdict) } else if state == .running { s.append("still running: \(saved.marker?.step ?? "")") }
        s += lines
        if let p = partial { s.append(p + " (still running)") }
        for (k, p) in previous.enumerated() { s.append("Previous attempt \(k + 1): \(p)") }
        if !ownResult.isEmpty, ownResult != "Working…" { s.append("Own photo:\n\(ownResult)") }
        s.append("steps: " + steps.map { "\($0.status) \($0.name) \($0.detail)" }.joined(separator: " | "))
        return s.joined(separator: "\n")
    }

    func copy() {
        UIPasteboard.general.string = reportText()
        copied = true
    }

    /// Mac test hook: `-autorun [-ownphoto <path>]` prints the report and quits.
    private func autorunTail() async {
        let args = CommandLine.arguments
        if let k = args.firstIndex(of: "-ownphoto"), k + 1 < args.count {
            classifyOwn(FileManager.default.contents(atPath: args[k + 1]))
            while ownBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        print("=== REPORT ===\n" + reportText() + "\n=== END ===")
        if args.contains("-exit") { exit(0) }
    }
}

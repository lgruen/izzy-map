import Foundation
import os
import UIKit

/// What the identifier's last load took (Diagnostics), and whether this
/// model has been loaded here before — the honest "the first time after an
/// update takes longer" line: Core ML specialises a model for the device
/// on its first load and caches that.
nonisolated enum PlantIDLoadLog {
    private static let loadedKey = "plantIDLoadedModel"
    private static let lastKey = "plantIDLastLoad"

    /// The installed model's identity: pipeline.json's model block (id, git,
    /// build date), else the file's modification date.
    static func modelKey(_ dir: URL) -> String {
        if let m = PlantIDModelIdentity.load(dir) { return [m.id, m.git, m.built].compactMap { $0 }.joined(separator: "|") }
        let date = (try? dir.appending(path: PlantIDFiles.pipeline).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "pipeline.json@\(date.map { "\($0.timeIntervalSince1970)" } ?? "?")"
    }

    /// No load of this model has completed on this device yet.
    static func isFirstLoad(_ dir: URL) -> Bool {
        UserDefaults.standard.string(forKey: loadedKey) != modelKey(dir)
    }

    static func record(dir: URL, took: Duration, steps: [String], location: PlantIDModelLocation, units: String) {
        let key = modelKey(dir)
        let first = UserDefaults.standard.string(forKey: loadedKey) != key
        UserDefaults.standard.set(key, forKey: loadedKey)
        let ms = Int((took / .milliseconds(1)).rounded())
        let line = "\(ms) ms · \(first ? "first load of this model here" : "model loaded here before")"
            + " · from \(location.rawValue) · compute units \(units)"
            + " (\(steps.joined(separator: ", "))) · \(Date.now.formatted(.iso8601))"
        UserDefaults.standard.set(line, forKey: lastKey)
    }

    /// The last completed load, as Diagnostics shows it.
    static var lastLine: String? { UserDefaults.standard.string(forKey: lastKey) }
}

/// Owns the loaded identifier at app level, beyond Identify's lifetime:
/// once loaded it stays for the rest of the run, so reopening Identify is
/// instant — until a memory warning (the encoder's weights are ~0.6 GB of
/// mapped file, its working memory more; the map wins) or a return from
/// more than 10 minutes in the background. Nothing loads before Identify
/// opens (the map is the main use); closing Identify mid-load calls the
/// load off.
@MainActor
final class PlantIDEngineKeeper {
    static let shared = PlantIDEngineKeeper()

    private var engine: PlantIDEngine?
    private var observers: [NSObjectProtocol] = []
    private var backgroundSince: Date?
    static let backgroundLimit: TimeInterval = 10 * 60
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")

    /// The kept engine for `source`, handed over to the Identify screen.
    func take(_ source: PlantIDSource) -> PlantIDEngine? {
        guard let engine, engine.source == source else {
            drop("another model")
            return nil
        }
        self.engine = nil
        return engine
    }

    /// Identify closed: keep its engine if it is loaded; a load still in
    /// flight is called off (it would only compete with the map).
    func keep(_ engine: PlantIDEngine) {
        drop(nil)
        self.engine = engine
        observe()
        Task {
            guard await engine.isLoaded else {
                await engine.release()
                if self.engine === engine { self.engine = nil }
                return
            }
            Self.logger.info("identifier kept after Identify closed · memory \(MemoryUse.line(), privacy: .public)")
        }
    }

    /// Every loaded identifier lets go (the Diagnostics benchmark measures
    /// on its own): the kept one here, an open Identify's encoder (it loads
    /// again when she identifies).
    static let releaseAll = Notification.Name("PlantIDReleaseAll")
    func releaseAll() {
        drop("benchmark")
        NotificationCenter.default.post(name: Self.releaseAll, object: nil)
    }

    private func drop(_ why: String?) {
        guard let engine else { return }
        if let why { Self.logger.notice("kept identifier released: \(why, privacy: .public)") }
        Task { await engine.release() }
        self.engine = nil
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.drop("memory warning") }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundSince = .now }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let since = self.backgroundSince else { return }
                    self.backgroundSince = nil
                    if Date.now.timeIntervalSince(since) > Self.backgroundLimit { self.drop("over 10 min in the background") }
                }
            },
        ]
    }
}

/// The app's memory as the system counts it: footprint (dirty + compressed
/// pages — what jetsam judges) and resident (incl. clean mapped pages the
/// system can drop, such as Core ML's mmapped weights).
nonisolated enum MemoryUse {
    /// The footprint alone, in MB (nil: unknown).
    static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }

    static func line() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return "unknown" }
        func mb(_ b: UInt64) -> String { "\(b / 1_048_576) MB" }
        return "footprint \(mb(info.phys_footprint)) · resident \(mb(info.resident_size)) · compressed \(mb(info.compressed))"
    }
}

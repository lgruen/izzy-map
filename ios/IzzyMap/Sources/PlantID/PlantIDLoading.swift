import Foundation
import os

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

    /// The model + the compute units it was specialised for: Core ML's
    /// on-device specialisation cache is per model and per units.
    static func loadKey(_ dir: URL, units: String) -> String { modelKey(dir) + "|" + units }

    /// No load of this model with these compute units has completed on this
    /// device yet (so Core ML will specialise it: ~30 s).
    static func isFirstLoad(_ dir: URL, units: String = CoreMLPlantEncoder.name(CoreMLPlantEncoder.defaultUnits)) -> Bool {
        UserDefaults.standard.string(forKey: loadedKey) != loadKey(dir, units: units)
    }

    static func record(dir: URL, took: Duration, steps: [String], location: PlantIDModelLocation, units: String) {
        let key = loadKey(dir, units: units)
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

/// Posted before the Diagnostics benchmark runs: an open Identify lets go
/// of its encoder (it reloads, ~0.3 s, when she identifies).
@MainActor
enum PlantIDRelease {
    static let all = Notification.Name("PlantIDReleaseAll")
    static func releaseAll() { NotificationCenter.default.post(name: all, object: nil) }
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

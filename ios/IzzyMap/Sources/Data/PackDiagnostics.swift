import BackgroundAssets
import Foundation
import System
import SwiftUI
import UIKit

/// A plain-text report of what the system and the app each think about every
/// asset pack: the evidence for "why isn't X here?" on a real device, where
/// there is no debugger (hidden screen: long-press "Model & training photos"
/// on Identify, or the gauge at the top of Storage). Release builds too —
/// nothing in it is secret: versions, states, file paths inside the app's
/// own containers, sizes.
enum PackDiagnostics {
    static func report(_ store: PackStore) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines: [String] = []
        lines.append("IzzyMap \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        lines.append("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) · \(machine()) · \(Date.now.formatted(.iso8601))")
        lines.append("online: \(Connectivity.shared.online)")
        let volume = VolumeSpace.current()
        lines.append("free: \(volume.free.map { StorageText.size(Int($0)) } ?? "?") of \(volume.capacity.map { StorageText.size(Int($0)) } ?? "?")")
        lines.append("store: \(store.mode) · resolved \(store.isResolved) · BA unavailable \(store.backgroundAssetsUnavailable)")
        lines.append("manifest: \(store.manifestLoaded ? "read" : "not read")\(store.manifestError.map { " · error \($0)" } ?? "")")
        for entry in store.catalogueLog { lines.append("catalogue: \(entry)") }
        lines.append("plant ID folder: \(store.plantIDDirectory?.path(percentEncoded: false) ?? "none")")
        lines.append("plant ID source: \(PlantIDSession.source(packs: store).map { "\($0)" } ?? "none")")
        lines.append(contentsOf: queueLines(store))
        let system = store.usesBackgroundAssets
        for pack in Pack.allCases {
            lines.append("")
            var head = "[\(pack.rawValue)] \(pack.policy) · ours: \(describe(store.state(pack)))"
            if store.current == pack { head += " · in flight" }
            if let n = store.queuePosition(pack) { head += " · queued #\(n)" }
            if let r = store.retries[pack], r > 0 { head += " · retries \(r)" }
            if let u = store.updates[pack] { head += " · updating \(Int(u * 100)) %" }
            if let v = store.manifestVersions[pack] { head += " · server v\(v)" }
            if let size = store.downloadSizes[pack] { head += " · download \(StorageText.size(size))" }
            lines.append(head)
            let systemInfo = system ? await systemLines(pack) : nil
            for error in store.errorLog[pack] ?? [] {
                let stale = staleness(of: error, state: store.state(pack), system: systemInfo?.status, lastSync: store.lastSync)
                lines.append("  error \(error.date.formatted(date: .omitted, time: .standard)) \(error.stage): \(error.text)\(stale)")
            }
            if let systemInfo { lines.append(contentsOf: systemInfo.lines) }
        }
        if !system { lines.append("\n(not Background Assets: the system isn't asked)") }
        return lines.joined(separator: "\n")
    }

    /// The download queue: what's in flight, what waits, and how.
    private static func queueLines(_ store: PackStore) -> [String] {
        var line = "queue: "
        if let current = store.current {
            line += "in flight \(current.rawValue) (retries \(store.retries[current] ?? 0)"
            if let at = store.retryAt { line += ", next retry \(at.formatted(date: .omitted, time: .standard))" }
            if let parked = store.parkedFor { line += ", \(parked.rawValue)" }
            line += ")"
        } else {
            line += "nothing in flight"
        }
        line += store.queue.isEmpty ? " · none waiting" : " · then " + store.queue.map(\.rawValue).joined(separator: ", ")
        line += " · call in flight: \(store.callInFlight?.rawValue ?? "none")"
        line += " · abandoned: \(store.abandonedCall?.rawValue ?? "none") (\(store.abandonedCount) this launch)"
        return [line,
                "app active \(store.isActive) · online \(store.online) · background task \(store.backgroundTaskRunning ? "running" : "none") · last sync \(store.lastSync?.formatted(date: .omitted, time: .standard) ?? "never")"]
    }

    /// Whether an error still describes the pack: " (stale: …)" when what
    /// the app and the system say now has moved on from it.
    private static func staleness(of error: PackStore.ErrorRecord, state: PackState, system: PackSystemStatus?, lastSync: Date?) -> String {
        if state.isInstalled { return " (stale: installed since)" }
        if let system, system.downloaded { return " (stale: the system has it now)" }
        if let system, system.downloading { return " (stale: the system is downloading it now)" }
        if case .downloading = state { return " (stale: downloading again)" }
        if let lastSync, lastSync < error.date { return " (newer than the last sync)" }
        return ""
    }

    /// What Background Assets says about one pack, and where each of its
    /// files resolves.
    @concurrent nonisolated private static func systemLines(_ pack: Pack) async -> (status: PackSystemStatus, lines: [String]) {
        let manager = AssetPackManager.shared
        var out: [String] = []
        let local = manager.assetPackIsAvailableLocally(withID: pack.rawValue)
        let status = await manager.localStatus(ofAssetPackWithID: pack.rawValue)
        var line = "  system: available locally \(local) · local status \(names(status)) (raw \(status.rawValue))"
        if #available(iOS 27.2, *) {
            line += " · local version " + ((try? manager.localVersion(ofAssetPackWithID: pack.rawValue)).map(String.init) ?? "none")
        }
        out.append(line)
        let summary = PackSystemStatus(downloading: status.contains(.downloading), downloaded: status.contains(.downloaded), raw: UInt(status.rawValue))
        var paths = pack.archives.map(\.fileName)
        paths += pack.otherFiles
        for path in paths {
            let isDir = path.hasSuffix("/")
            let name = isDir ? String(path.dropLast()) : path
            let url: URL
            do {
                url = try manager.url(for: FilePath(name))
            } catch {
                out.append("  \(path): url(for:) threw \(error)")
                continue
            }
            out.append("  \(path) → \(url.path(percentEncoded: false))")
            out.append("    \(probe(url))")
            if !isDir, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == nil {
                // the other two access paths, for comparison
                let viaContents = (try? manager.contents(at: FilePath(name), searchingInAssetPackWithID: pack.rawValue)).map { "\($0.count) bytes" }
                out.append("    contents(at:): \(viaContents ?? "failed")")
            }
            if isDir {
                for (rel, size) in listing(url).prefix(20) { out.append("    · \(rel) \(size)") }
            }
        }
        return (summary, out)
    }

    nonisolated private static func probe(_ url: URL) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return "missing" }
        if isDir.boolValue {
            let total = listing(url).reduce(0) { $0 + $1.1 }
            return "directory · \(StorageText.size(total)) · readable \(fm.isReadableFile(atPath: path))"
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        return "file · \(size) bytes · readable \(fm.isReadableFile(atPath: path))"
    }

    nonisolated private static func listing(_ dir: URL) -> [(String, Int)] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        var out: [(String, Int)] = []
        let base = dir.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            let rel = url.standardizedFileURL.path(percentEncoded: false).replacingOccurrences(of: base, with: "")
            out.append((rel, v?.fileSize ?? 0))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    @available(iOS 26, *)
    nonisolated private static func names(_ s: AssetPack.Status) -> String {
        let all: [(AssetPack.Status, String)] = [(.downloadAvailable, "downloadAvailable"), (.updateAvailable, "updateAvailable"),
                                                 (.upToDate, "upToDate"), (.outOfDate, "outOfDate"), (.obsolete, "obsolete"),
                                                 (.downloading, "downloading"), (.downloaded, "downloaded")]
        let found = all.filter { s.contains($0.0) }.map(\.1)
        return found.isEmpty ? "[]" : "[" + found.joined(separator: ", ") + "]"
    }

    private static func describe(_ state: PackState) -> String {
        switch state {
        case .notInstalled: "not installed"
        case let .downloading(f): "downloading " + (f.map { "\(Int($0 * 100)) %" } ?? "(no progress yet)")
        case .paused: "paused"
        case .installed: "installed"
        case let .failed(why): "failed: \(why)"
        case .unpublished: "unpublished (not in the server's manifest / not found)"
        }
    }

    private static func machine() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The hidden Diagnostics screen: the report, selectable, with Copy.
struct PackDiagnosticsView: View {
    let packs: PackStore
    @State private var report = "Gathering…"
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(report)
                .font(.caption.monospaced())
                .foregroundStyle(DesignColor.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .accessibilityIdentifier("diagnostics-report")
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = report
                    copied = true
                }
                .accessibilityIdentifier("diagnostics-copy")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await gather() } }
            }
        }
        .task { await gather() }
    }

    private func gather() async {
        copied = false
        // the store's states from the system first: the report shows both
        // views, and an old error is marked stale against the new one
        await packs.resync()
        report = await PackDiagnostics.report(packs)
    }
}

import BackgroundAssets
import Foundation
import IzzyKit
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
        lines.append("memory: \(MemoryUse.line())")
        let volume = VolumeSpace.current()
        lines.append("free: \(volume.free.map { StorageText.size(Int($0)) } ?? "?") of \(volume.capacity.map { StorageText.size(Int($0)) } ?? "?")")
        lines.append("store: \(store.mode) · resolved \(store.isResolved) · BA unavailable \(store.backgroundAssetsUnavailable)")
        lines.append("manifest: \(store.manifestLoaded ? "read" : "not read")\(store.manifestError.map { " · error \($0)" } ?? "")")
        for entry in store.catalogueLog { lines.append("catalogue: \(entry)") }
        lines.append("plant ID folder: \(store.plantIDDirectory?.path(percentEncoded: false) ?? "none")")
        lines.append("plant ID source: \(PlantIDSession.source(packs: store).map { "\($0)" } ?? "none")")
        lines.append("Identify open: \(PlantIDOpenTiming.lastLine ?? "none recorded")")
        if case let .files(dir)? = PlantIDSession.source(packs: store) {
            let id = await Task.detached { PlantIDModelIdentity.load(dir) }.value
            lines.append("plant ID model: \(id.map { "\($0.line)\($0.summary.map { " · \($0)" } ?? "")" } ?? "no pipeline.json model block")")
            lines.append("plant ID last load: \(PlantIDLoadLog.lastLine ?? "none recorded")")
            let copy = await Task.detached { PlantIDModelCopy.describe() }.value
            lines.append("plant ID app copy: \(copy ?? "none")")
        }
        if let dir = PlantIDRefPhotos.locate(packs: store) {
            let index = await Task.detached {
                try? JSONDecoder().decode(PlantIDRefIndex.self, from: Data(contentsOf: dir.appending(path: RefPhotoFiles.index)))
            }.value
            let modified = (try? dir.appending(path: RefPhotoFiles.index).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate.map { $0.formatted(.iso8601.year().month().day()) }
            lines.append("reference photos: \(index.map { "\($0.photos.count.formatted()) species with a photo · built \($0.built ?? modified ?? "?")" } ?? "index.json unreadable") · \(dir.path(percentEncoded: false))")
        } else {
            lines.append("reference photos: none")
        }
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
            if store.repairing.contains(pack) { head += " · REPAIRING (damaged files removed, downloading again)" }
            lines.append(head)
            var report = store.integrity[pack]
            if report == nil, store.lastFound?.installed.contains(pack) == true { report = await store.checkIntegrityNow(pack) }
            if let report { lines.append(contentsOf: integrityLines(report)) }
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

    /// The integrity check per file ("size ok" / "TRUNCATED (have X, need
    /// Y)"); a long sample (reference photos) only its damaged files.
    private static func integrityLines(_ report: PackIntegrity.Report) -> [String] {
        let verdict = report.isDamaged ? "DAMAGED" : report.isConclusive ? "complete" : "not all checked"
        var out = ["  files: \(verdict) (\(report.files.count) checked)"]
        let shown = report.files.count <= 12 ? report.files : report.files.filter { $0.verdict != .ok }
        for file in shown.prefix(20) { out.append("    \(file.path): \(file.line)") }
        return out
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
        var out = [store.callInFlight?.rawValue, store.abandonedCall.map { "\($0.rawValue) (abandoned)" }].compactMap { $0 }
        if out.isEmpty { out = ["none"] }
        line += " · calls out: \(out.joined(separator: ", ")) · abandoned this launch: \(store.abandonedCount)"
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
        var deniedProbed = false
        for path in paths {
            let isDir = path.hasSuffix("/")
            let name = isDir ? String(path.dropLast()) : path
            let url: URL
            do {
                url = try manager.url(for: FilePath(name))
            } catch {
                out.append("  \(path): url(for:) threw \(error)")
                if !deniedProbed, !isDir {
                    deniedProbed = true
                    out += deniedLines(error, file: name, pack: pack, manager: manager)
                }
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

    /// When `url(for:)` throws (2026-11-08, iPhone: "no permission to save
    /// Staged Subpaths.plist" for every downloaded pack, surviving a
    /// reboot): what the folder it wanted to write looks like from the app
    /// — owner, mode, flags, ACL, listable, writable — and whether the
    /// other access path, `descriptor(for:)`, still opens the file.
    nonisolated private static func deniedLines(_ error: any Error, file: String, pack: Pack, manager: AssetPackManager) -> [String] {
        var out: [String] = []
        do {
            let fd = try manager.descriptor(for: FilePath(file), searchingInAssetPackWithID: pack.rawValue)
            var st = stat()
            let r = fstat(fd.rawValue, &st)
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let p = fcntl(fd.rawValue, F_GETPATH, &buf) == 0 ? String(cString: buf) : "?"
            out.append("    descriptor(for:): ok · \(r == 0 ? "\(st.st_size) bytes" : "fstat errno \(errno)") · \(p)")
            try? fd.close()
        } catch {
            out.append("    descriptor(for:) threw \(error)")
        }
        let ns = error as NSError
        guard let plist = (ns.userInfo[NSURLErrorKey] as? URL) ?? (ns.userInfo["NSURL"] as? URL) else { return out }
        let folder = plist.deletingLastPathComponent()
        for (label, url) in [("pack folder", folder), ("Staged Subpaths.plist", plist), ("Asset Packs", folder.deletingLastPathComponent()),
                             ("app folder", folder.deletingLastPathComponent().deletingLastPathComponent())] {
            out.append("    \(label): \(fileFacts(url))")
        }
        let fm = FileManager.default
        do {
            let names = try fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
            out.append("    pack folder lists \(names.count): \(names.prefix(12).joined(separator: ", "))")
            for name in names.prefix(12) {
                out.append("      \(name): \(fileFacts(folder.appending(path: name)))")
            }
        } catch {
            out.append("    pack folder list failed: \(error.localizedDescription)")
        }
        // a direct read of the pack's own copy (no staging): readable at all?
        let direct = folder.appending(path: file)
        if let h = try? FileHandle(forReadingFrom: direct) {
            let head = (try? h.read(upToCount: 7)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            out.append("    direct read \(file): ok, starts \"\(head.filter { $0.isASCII && !$0.isNewline })\"")
            try? h.close()
        } else {
            out.append("    direct read \(file): can't open")
        }
        return out
    }

    /// "uid 501 gid 501 drwxr-xr-x flags 0x0 · access r w x · acl …".
    nonisolated private static func fileFacts(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0 else { return "lstat errno \(errno) (\(String(cString: strerror(errno))))" }
        let kind = switch st.st_mode & S_IFMT { case S_IFDIR: "d"; case S_IFLNK: "l"; case S_IFREG: "-"; default: "?" }
        let mode = String(st.st_mode & 0o7777, radix: 8)
        let can = [(R_OK, "r"), (W_OK, "w"), (X_OK, "x")].map { access(path, $0.0) == 0 ? $0.1 : "-" }.joined()
        var line = "\(kind) uid \(st.st_uid) gid \(st.st_gid) mode \(mode) flags 0x\(String(st.st_flags, radix: 16)) size \(st.st_size) · access \(can)"
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            if let text = acl_to_text(acl, nil) {
                line += " · acl " + String(cString: text).split(separator: "\n").dropFirst().joined(separator: "; ")
                acl_free(UnsafeMutableRawPointer(text))
            }
            acl_free(UnsafeMutableRawPointer(acl))
        }
        line += " · me uid \(getuid())"
        return line
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
            if case let .files(dir)? = PlantIDSession.source(packs: packs) {
                PlantIDBenchmarkSection(dir: dir)
                    .padding([.horizontal, .top], 16)
            }
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

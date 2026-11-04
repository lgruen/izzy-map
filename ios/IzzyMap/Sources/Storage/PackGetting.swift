import SwiftUI

/// A fetch that won't fit: what was asked for and what it needs.
struct PackSpaceRequest: Identifiable, Equatable {
    let id = UUID()
    let packs: [Pack]
    let title: String
    /// Download + unpacked + nothing else (the margin is said in words).
    let need: Int64
    /// What the packs take once they're on the device.
    let unpacked: Int64
    let free: Int64?
}

extension PackStore {
    /// One tap: queues every pack in `list` that isn't on the device, in
    /// that order —
    /// unless they don't fit, then returns the request for the space alert
    /// (`packSpaceAlert`), which can still go ahead.
    func get(_ list: [Pack], title: String) -> PackSpaceRequest? {
        let wanted = list.filter { !state($0).isInstalled }
        guard !wanted.isEmpty else { return nil }
        let need = SpacePreflight.need(wanted, downloadSizes: downloadSizes)
        let free = VolumeSpace.current().free
        if SpacePreflight.shortfall(need: need, free: free) != nil {
            let unpacked = wanted.reduce(Int64(0)) { $0 + Int64(PackSizes.nominal[$1] ?? downloadSizes[$1] ?? 0) }
            return PackSpaceRequest(packs: wanted, title: title, need: need, unpacked: unpacked, free: free)
        }
        fetch(wanted)
        return nil
    }
}

extension View {
    /// "Not enough free space": Try Anyway fetches, Cancel doesn't.
    func packSpaceAlert(_ request: Binding<PackSpaceRequest?>, store: PackStore) -> some View {
        alert("Not Enough Free Space", isPresented: Binding(get: { request.wrappedValue != nil },
                                                           set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { r in
            Button("Try Anyway") {
                store.fetch(r.packs)
            }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            let free = r.free.map { " This \(DeviceNoun.current) has \(StorageText.size(Int($0))) free." } ?? ""
            Text("\(r.title) takes \(StorageText.size(Int(r.unpacked))) once it's here, but while it arrives the download and the unpacked map sit side by side: about \(StorageText.about(Int(r.need))) free, plus room for the system.\(free) Remove something in Storage first, or try anyway.")
        }
    }
}

/// The small control on a Layers tile whose pack isn't on the device: a
/// download arrow (one tap gets the pack), a progress ring while it comes,
/// a still ring while it stands still. Sits on the thumbnail's corner. A
/// ring with an arrow in it: some of the tile's packs are coming, the rest
/// are one tap away (the seasons tile).
struct TileDownloadBadge: View {
    let status: PackRowStatus
    /// A tap gets something (idle packs remain).
    var canGet: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white)
                switch status {
                case let .downloading(f):
                    ProgressRing(fraction: f, lineWidth: 2.5, color: .black)
                        .padding(3)
                    if canGet { Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)) }
                case .paused, .queued:
                    ProgressRing(fraction: 0, lineWidth: 2.5, color: .black).padding(3)
                    if canGet { Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)) }
                default:
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(Color.black)
            .frame(width: 24, height: 24)
            .overlay { Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5) }
            .padding(4)
            .frame(width: 40, height: 40, alignment: .bottomTrailing)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canGet)
        // the tile's own label says it; the action is on the tile (below)
        .accessibilityHidden(true)
    }
}

/// A determinate ring in ink (nil: a spinning arc; 0: an empty, still ring).
/// `color`: the ink; a ring on a white disc passes black (in dark mode the
/// label colour is white — a pale arc on the disc).
struct ProgressRing: View {
    var fraction: Double?
    var lineWidth: CGFloat = 3
    var color: Color = DesignColor.ink

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            } else if fraction == nil {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
        }
    }
}

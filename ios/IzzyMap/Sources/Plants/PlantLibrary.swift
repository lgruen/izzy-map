import Foundation
import IzzyKit
import Observation
import os
import SwiftUI

/// The bundled plant data (plants.json + records.json + nearby.bin), the
/// F2F page index and the mini-maps' tables, loaded once per process off
/// the main thread and shared by every window. A failure is not cached:
/// the next card tries again.
@MainActor @Observable
final class PlantLibrary {
    static let shared = PlantLibrary()

    private(set) var catalog: PlantCatalog?
    private(set) var failed = false
    /// The Plants section was opened: later cards this session open
    /// expanded too (not persisted).
    var sectionExpanded = false
    @ObservationIgnored private var loading: Task<PlantCatalog?, Never>?

    /// The F2F page index (10 KB, loaded on first use).
    @ObservationIgnored private(set) lazy var f2f: F2FIndex? = try? BundledData.inBundle()?.f2fIndex()
    @ObservationIgnored private(set) lazy var outline: TasmaniaOutline? = try? BundledData.inBundle()?.tasmaniaOutline()
    /// where.bin (pipeline/build_where.py); nil until it ships.
    @ObservationIgnored private(set) lazy var presence: CommunityPresence? = {
        do { return try BundledData.inBundle()?.communityPresence() } catch {
            Self.logger.error("where.bin unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()
    @ObservationIgnored private(set) lazy var patches: CommunityPatches? = try? BundledData.inBundle()?.communityPatches()

    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Plants")

    func load() async -> PlantCatalog? {
        if let catalog { return catalog }
        if let loading { return await loading.value }
        let task = Task.detached(priority: .userInitiated) { () -> PlantCatalog? in
            do {
                guard let data = BundledData.inBundle() else { return nil }
                return try data.plantCatalog()
            } catch {
                Self.logger.fault("plant data unreadable: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        loading = task
        let result = await task.value
        loading = nil
        catalog = result
        failed = result == nil
        return result
    }
}

/// Where a plant list was opened from: the community and the tapped point.
nonisolated struct PlantContext: Hashable, Sendable {
    var code: String?
    var latitude: Double?
    var longitude: Double?
}

/// What the panel's navigation stack can push over a card.
nonisolated enum CardRoute: Hashable, Sendable {
    /// A broad-sense group's member list.
    case group(key: String, context: PlantContext)
    /// A plant sheet. `source` names the row it zooms out of.
    case plant(id: Int, key: String, context: PlantContext, source: String)
}

extension EnvironmentValues {
    /// The namespace row thumbnails and plant sheets share for the zoom transition.
    @Entry var cardNamespace: Namespace.ID?
}


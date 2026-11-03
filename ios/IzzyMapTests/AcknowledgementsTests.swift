import Foundation
import IzzyKit
import MapLibre
import Testing
@testable import IzzyMap

/// The acknowledgements in the built app belong to the MapLibre that is
/// actually linked (a version bump without re-running
/// pipeline/build_acknowledgements.py fails here).
struct AppAcknowledgementsTests {
    @Test func bundledAndMatchTheLinkedMapLibre() throws {
        let doc = try #require(BundledData.inBundle()).acknowledgements()
        let linked = try #require(Bundle(for: MLNMapView.self).infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(doc.component("maplibre")?.version == linked)
        #expect(doc.component("bioclip")?.licence == "MIT")
    }
}

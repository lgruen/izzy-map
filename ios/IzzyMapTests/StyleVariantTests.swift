import Foundation
import IzzyKit
import MapLibre
import Testing
import UIKit
@testable import IzzyMap

/// Every style the app can show — each base × overlay × strength × relief ×
/// trees × "Show on map" × key highlight, online and offline — parsed by
/// MapLibre itself, and rendered at four zooms over Hobart and the Central
/// Highlands when the developer's packs are there (`-dataDir`, the scheme's
/// Run arguments; CI has none and only parses).
///
/// Written for the 2026-11-03 crash reports (EXC_BAD_ACCESS in
/// `CompoundExpression::evaluate` under a fill colour): that crash was the
/// unit-test host's `exit()` freeing MapLibre's expression registry under
/// live tile workers (IzzyMapApp.isUnitTestHost), not an expression — this
/// suite is the proof that every variant's expressions parse and evaluate.
@MainActor
@Suite(.serialized) struct StyleVariantTests {
    struct Variant: CustomStringConvertible {
        var state: LayerState
        /// "Show on map" for this community (vegetation only, as in the app).
        var spotlight: String?
        /// A key row / tapped community: the dashes and a tapped polygon id.
        var key: String?
        var online: Bool

        var description: String {
            "\(state.base.rawValue)/\(state.overlay.rawValue)/\(state.strength.rawValue)"
                + (state.relief ? "+relief" : "") + (state.trees ? "+trees" : "")
                + (spotlight.map { " spotlight \($0)" } ?? "") + (key.map { " key \($0)" } ?? "")
                + (online ? "" : " offline")
        }
    }

    static let spotlightCode = "DCO"
    static let keyCode = "DOB"

    static let variants: [Variant] = {
        var out: [Variant] = []
        for base in BaseMap.allCases {
            for overlay in Overlay.allCases {
                for strength in Strength.allCases {
                    for relief in [false, true] {
                        for trees in [false, true] {
                            for spotlight in [nil, spotlightCode] {
                                for key in [nil, keyCode] {
                                    for online in [true, false] {
                                        var state = LayerState.default
                                        state.base = base
                                        state.overlay = overlay
                                        state.strength = strength
                                        state.relief = relief
                                        state.trees = trees
                                        out.append(Variant(state: state, spotlight: overlay == .vegetation ? spotlight : nil,
                                                           key: key, online: online))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }()

    /// The style object MapLibre sees for a variant: StyleBuilder's, with the
    /// selection and the spotlight's runtime fade baked in (the values
    /// SpotlightPresenter sets: `StyleBuilder.spotlightFade`).
    static func style(_ v: Variant, data: DataLocation, tables: MapTables) -> [String: Any] {
        let selection = v.key.map { SelectionStyle(featureID: 4242, community: $0) } ?? .none
        var style = StyleBuilder.style(state: v.state, data: data, tables: tables, selection: selection, online: v.online)
        guard let code = v.spotlight else { return style }
        let fade = StyleBuilder.spotlightFade(code: code, fillOpacity: v.state.fillOpacity)
        let L = StyleBuilder.LayerID.self
        style["layers"] = (style["layers"] as? [[String: Any]] ?? []).map { layer in
            var layer = layer
            var paint = layer["paint"] as? [String: Any] ?? [:]
            switch layer["id"] as? String ?? "" {
            case L.tasvegFill: paint["fill-opacity"] = fade.fill
            case L.tasvegBand: paint["line-opacity"] = fade.band
            case let id where id.hasPrefix(L.tasvegLabel): paint["text-opacity"] = fade.label
            default: return layer
            }
            layer["paint"] = paint
            return layer
        }
        return style
    }

    static func json(_ style: [String: Any]) -> String {
        let bytes = (try? JSONSerialization.data(withJSONObject: style, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    static func layerIDs(_ style: [String: Any]) -> [String] {
        (style["layers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// The host window has no map (the crash's fix): XCTest's exit() can't
    /// race tile workers the tests didn't start.
    @Test func theTestHostShowsNoMap() {
        #expect(IzzyMapApp.isUnitTestHost)
    }

    // MARK: Parse (always; no data needed)

    /// MapLibre drops a layer whose paint, layout or filter fails to parse
    /// (and logs a warning): every layer of every variant must survive into
    /// the loaded style, in order. Fake pack paths (`/data/…`, never read:
    /// a map without a window requests no tiles) put every source in.
    @Test func everyVariantParsesInMapLibre() async throws {
        let tables = StyleBuilderTests.bundled
        try #require(!tables.communities.isEmpty && !tables.geology.isEmpty, "bundled tables")
        let data = StyleBuilderTests.all
        var problems: [String] = []
        let log = LogCapture()
        log.start()
        defer { log.stop() }

        var seen: Set<String> = []
        var parsed = 0
        for v in Self.variants {
            let style = Self.style(v, data: data, tables: tables)
            let json = Self.json(style)
            guard seen.insert(json).inserted else { continue }
            parsed += 1
            autoreleasepool {
                let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), styleJSON: json)
                guard let loaded = map.style else { problems.append("\(v): no style"); return }
                // minus MapLibre's own annotation layer
                let ids = loaded.layers.map(\.identifier).filter { !$0.hasPrefix("org.maplibre.") }
                let expected = Self.layerIDs(style)
                if ids != expected {
                    problems.append("\(v): MapLibre kept \(ids.count)/\(expected.count) layers, missing \(Set(expected).subtracting(ids).sorted()), extra \(ids.filter { !expected.contains($0) })")
                }
                // data-driven paint survived as expressions, not the defaults
                if let fill = loaded.layer(withIdentifier: StyleBuilder.LayerID.tasvegFill) as? MLNFillStyleLayer,
                   fill.fillColor.expressionType == .constantValue {
                    problems.append("\(v): tasveg fill colour lost its match")
                }
                if let spotlight = v.spotlight {
                    problems += Self.presenterProblems(v, code: spotlight, map: map, data: data, tables: tables)
                }
            }
        }
        // every base × overlay × strength reached MapLibre
        #expect(parsed >= BaseMap.allCases.count * Overlay.allCases.count * Strength.allCases.count, "\(parsed)")
        // MapLibre logs asynchronously
        try await Task.sleep(for: .milliseconds(500))
        let parseWarnings = log.messages.filter(Self.isParseProblem)
        #expect(problems.isEmpty, "\(problems.prefix(20).joined(separator: "\n"))")
        #expect(parseWarnings.isEmpty, "\(parseWarnings.prefix(20).joined(separator: "\n"))")
    }

    /// The oracle works: a fill colour MapLibre can't type (a `match` whose
    /// outputs mix a colour and a number) loses its layer, and says so.
    @Test func aBadExpressionIsCaught() async throws {
        let log = LogCapture()
        log.start()
        defer { log.stop() }
        let json = ##"{"version":8,"sources":{"s":{"type":"geojson","data":{"type":"FeatureCollection","features":[]}}},"layers":[{"id":"bg","type":"background"},{"id":"bad","type":"fill","source":"s","paint":{"fill-color":["match",["get","VEGCODE"],"DOB","#ff0000",7]}}]}"##
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), styleJSON: json)
        let ids = map.style?.layers.map(\.identifier) ?? []
        #expect(ids.contains("bg") && !ids.contains("bad"), "\(ids)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.messages.contains(where: Self.isParseProblem), "\(log.messages)")
    }

    /// The real SpotlightPresenter on the loaded style: its runtime presence
    /// layers go in (above the fills, below the dashes) and the fade lands.
    private static func presenterProblems(_ v: Variant, code: String, map: MLNMapView, data: DataLocation,
                                          tables: MapTables) -> [String] {
        let model = AppModel(data: data, tables: tables, layers: v.state)
        model.showOnMap(code)
        guard let spotlight = model.spotlight else { return ["\(v): showOnMap gave no spotlight"] }
        let presenter = SpotlightPresenter(camera: MapCamera())
        presenter.apply(spotlight, framing: .zero, model: model, to: map)
        defer { presenter.apply(nil, framing: .zero, model: model, to: map) }
        guard let style = map.style else { return ["\(v): style gone"] }
        var problems: [String] = []
        let ids = style.layers.map(\.identifier)
        for id in StyleBuilder.LayerID.spotlight where !ids.contains(id) {
            problems.append("\(v): spotlight layer \(id) missing")
        }
        if let fill = style.layer(withIdentifier: StyleBuilder.LayerID.tasvegFill) as? MLNFillStyleLayer,
           fill.fillOpacity.expressionType == .constantValue {
            problems.append("\(v): spotlight fade not applied")
        }
        return problems
    }

    /// MapLibre's own words for a style it could not take whole: its
    /// `ParseStyle` events (not source loading — the fake `/data/…` packs).
    nonisolated static func isParseProblem(_ message: String) -> Bool {
        message.contains("ParseStyle")
    }

    // MARK: Render (with the developer's packs)

    nonisolated struct Camera: Sendable {
        let name: String
        let latitude: Double, longitude: Double, zoom: Double
    }

    static let places: [(String, Double, Double)] = [("Hobart", -42.8821, 147.3272), ("Central Highlands", -41.98, 146.72)]
    static let zooms: [Double] = [5, 9, 12, 14]
    static let cameras: [Camera] = places.flatMap { name, lat, lon in
        zooms.map { Camera(name: "\(name) z\(Int($0))", latitude: lat, longitude: lon, zoom: $0) }
    }

    /// Every base × overlay × strength, the four toggles cycling through
    /// all 16 combinations across them (all 768 with
    /// `TEST_RUNNER_IZZY_RENDER_ALL=1`), offline (packs only: no network
    /// in a test), each at every camera. A crash here kills the test host.
    @Test func everyVariantRendersOverHobartAndTheHighlands() async throws {
        let data = DataLocator.locate()
        guard data.url(for: .topo) != nil, data.url(for: .tasveg) != nil else {
            // CI: no packs — the parse test above still checked every expression
            return
        }
        let tables = StyleBuilderTests.bundled
        var chosen: [Variant] = []
        if ProcessInfo.processInfo.environment["IZZY_RENDER_ALL"] == "1" {
            var seen: Set<String> = []
            chosen = Self.variants.filter { !$0.online && seen.insert($0.description).inserted }
        } else {
            var combo = 0
            for base in BaseMap.allCases {
                for overlay in Overlay.allCases {
                    for strength in Strength.allCases {
                        // 5 is coprime to 16: the 48 combinations walk all 16 toggle sets
                        let t = (combo * 5) % 16
                        combo += 1
                        var state = LayerState.default
                        state.base = base
                        state.overlay = overlay
                        state.strength = strength
                        state.relief = t & 1 != 0
                        state.trees = t & 2 != 0
                        chosen.append(Variant(state: state,
                                              spotlight: t & 4 != 0 && overlay == .vegetation ? Self.spotlightCode : nil,
                                              key: t & 8 != 0 ? Self.keyCode : nil, online: false))
                    }
                }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "style-variants", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var failures: [String] = []
        var rendered = 0, retried = 0
        for (i, v) in chosen.enumerated() {
            let file = directory.appending(path: "v\(i).json")
            try Data(Self.json(Self.style(v, data: data, tables: tables)).utf8).write(to: file)
            for camera in Self.cameras {
                var (image, error) = await Self.snapshot(style: file, camera: camera)
                // MapLibre now and then fails a snapshot's bundled glyph
                // request (an EMPTY request URL, "unsupported URL", for
                // asset://glyphs; ~1–2 in 384 snapshots, a different one
                // each run, twice in a row seen once): a resource hiccup,
                // not the style — up to three retries
                for _ in 0 ..< 3 where image == nil {
                    retried += 1
                    (image, error) = await Self.snapshot(style: file, camera: camera)
                }
                if let image, image.size.width > 0 { rendered += 1 } else { failures.append("\(v) @ \(camera.name): \(error ?? "no image")") }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
        #expect(rendered == chosen.count * Self.cameras.count)
        #expect(retried <= chosen.count * Self.cameras.count / 20, "\(retried) snapshots needed a retry")
    }

    static func snapshot(style: URL, camera: Camera) async -> (UIImage?, String?) {
        let options = MLNMapSnapshotOptions(
            styleURL: style,
            camera: MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
                                 altitude: 0, pitch: 0, heading: 0),
            size: CGSize(width: 128, height: 128))
        options.zoomLevel = camera.zoom
        options.scale = 1
        options.showsLogo = false
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        // `start` calls back on the main queue; the snapshotter must live
        // until then (and is released before the next one starts, so no
        // tile worker outlives the test)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(UIImage?, String?), Never>) in
            snapshotter.start { snapshot, error in
                continuation.resume(returning: (snapshot?.image, error.map { "\($0)" }))
            }
        }
        withExtendedLifetime(snapshotter) {}
        return result
    }
}

/// Collects MapLibre's warnings and errors while a test runs, then hands
/// the log back to MapLogging.
nonisolated final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var messages: [String] { lock.withLock { collected } }

    func start() {
        let config = MLNLoggingConfiguration.shared
        config.loggingLevel = .warning
        config.handler = { @Sendable [weak self] level, _, _, message in
            guard level == .warning || level == .error || level == .fault else { return }
            self?.lock.withLock { self?.collected.append(message) }
        }
    }

    func stop() { MapLogging.install() }
}

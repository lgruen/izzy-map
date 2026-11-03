import Foundation
import IzzyKit
import MapLibre
import Testing
import UIKit
@testable import IzzyMap

/// "Show on map" and search flights frame an extent WHOLE inside the map
/// area no chrome covers, centred there (finding 3: asymmetric insets; the
/// m45 critique: DAM cut at the west edge, DOB's Huon/Bruny under the iPad's
/// bottom ornaments, DMO's third patch under the search card).
@MainActor
@Suite struct MapFramingTests {
    // MARK: MapFraming (measured chrome → unobscured insets)

    @Test func phoneChromePushesTopAndBottom() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let safe = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        let pill = CGRect(x: 16, y: 63, width: 280, height: 66)  // two lines
        let controls = CGRect(x: 326, y: 63, width: 48, height: 112)
        let sheet = CGRect(x: 8, y: 724, width: 374, height: 120)
        let grid = CGRect(x: 8, y: 664, width: 220, height: 52)
        let i = CGRect(x: 342, y: 676, width: 40, height: 40)
        let insets = MapFraming.insets(bounds: bounds, safe: safe, obstructions: [pill, controls, sheet, grid, i])
        // a measured two-line pill, not an assumed +52
        #expect(insets.top >= pill.maxY)
        #expect(insets.bottom >= bounds.maxY - grid.minY)
        let free = bounds.inset(by: insets)
        for o in [pill, controls, sheet, grid, i] { #expect(!free.intersects(o), "\(o)") }
        #expect(free.height > 400)
    }

    @Test func iPadLandscapeKeepsClearOfTheCardAndOrnaments() {
        let bounds = CGRect(x: 0, y: 0, width: 1210, height: 834)
        let safe = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        let shortCard = CGRect(x: 16, y: 40, width: 380, height: 110)  // search field only
        let controls = CGRect(x: 1146, y: 40, width: 48, height: 112)
        let pill = CGRect(x: 520, y: 40, width: 300, height: 52)
        let grid = CGRect(x: 16, y: 760, width: 260, height: 52)
        let i = CGRect(x: 1154, y: 772, width: 40, height: 40)
        let short = MapFraming.insets(bounds: bounds, safe: safe, obstructions: [shortCard, controls, pill, grid, i])
        // a short card costs the top edge, not a 400 pt column
        #expect(short.left == 0 && short.top >= shortCard.maxY)
        let tallCard = CGRect(x: 16, y: 40, width: 380, height: 700)
        let tall = MapFraming.insets(bounds: bounds, safe: safe, obstructions: [tallCard, controls, pill, grid, i])
        #expect(tall.left >= tallCard.maxX)
        for o in [tallCard, controls, pill, grid, i] { #expect(!bounds.inset(by: tall).intersects(o), "\(o)") }
    }

    // MARK: The camera (a real MLNMapView's transform)

    private static let style = ##"{"version":8,"sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"#ffffff"}}]}"##

    private func map(_ size: CGSize, content: UIEdgeInsets) -> MLNMapView {
        let map = MLNMapView(frame: CGRect(origin: .zero, size: size), styleJSON: Self.style)
        map.automaticallyAdjustsContentInset = false
        map.contentInset = content
        map.setCenter(CLLocationCoordinate2D(latitude: -42, longitude: 146.5), zoomLevel: 7, animated: false)
        return map
    }

    /// Frames `box` like SpotlightPresenter (fit, then a cut with the same
    /// insets) and checks every corner lands inside the unobscured rect,
    /// the box centred there unless the zoom cap made it smaller.
    private func expectFramed(_ box: [Double], maxZoom: Double, framing: UIEdgeInsets, in map: MLNMapView,
                              _ label: String) {
        let insets = SpotlightPresenter.insets(framing: framing)
        let target = MapCamera.fit(box, maxZoom: maxZoom, insets: insets, in: map)
        MapCamera().move(map, to: target, insets: insets, duration: 0)
        let free = map.bounds.inset(by: insets)
        let corners = [(box[1], box[0]), (box[1], box[2]), (box[3], box[0]), (box[3], box[2])].map {
            map.convert(CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1), toPointTo: map)
        }
        for p in corners {
            #expect(free.insetBy(dx: -1, dy: -1).contains(p), "\(label): \(p) outside \(free)")
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let mid = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        #expect(abs(mid.x - free.midX) < 2 && abs(mid.y - free.midY) < 2, "\(label): centred at \(mid), free \(free)")
        #expect(map.zoomLevel <= maxZoom + 1e-6, "\(label)")
    }

    @Test func overviewsAndPatchesFitTheUnobscuredAreaOnPhoneAndIPad() throws {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.layers.overlay = .vegetation
        let layouts: [(String, CGSize, UIEdgeInsets, UIEdgeInsets)] = [
            // phone: safe area + glance sheet as content inset; pill, controls, ornaments, sheet as framing
            ("iPhone", CGSize(width: 390, height: 844), UIEdgeInsets(top: 47, left: 0, bottom: 120, right: 0),
             UIEdgeInsets(top: 129, left: 0, bottom: 180, right: 64)),
            // iPad landscape with a tall card on the leading side
            ("iPad", CGSize(width: 1210, height: 834), UIEdgeInsets(top: 24, left: 0, bottom: 28, right: 0),
             UIEdgeInsets(top: 92, left: 412, bottom: 80, right: 80)),
        ]
        for (name, size, content, framing) in layouts {
            let map = map(size, content: content)
            for code in ["DAM", "DOB", "DMO"] {
                model.showOnMap(code)
                var s = try #require(model.spotlight)
                let free = map.bounds.inset(by: SpotlightPresenter.insets(framing: framing))
                let aspect = Double(free.width / free.height)
                expectFramed(s.bounds(aspect: aspect), maxZoom: s.maxZoom, framing: framing, in: map, "\(name) \(code) overview")
                s.step = 1
                expectFramed(s.bounds(aspect: aspect), maxZoom: s.maxZoom, framing: framing, in: map, "\(name) \(code) patch 1")
            }
        }
    }

    /// The m45 critique: the iPad's DOB overview cropped the Huon and Bruny,
    /// and its DMO overview hid a patch under the search card.
    @Test func iPadOverviewsShowTheHuonBrunyAndEveryDMOPatch() throws {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.layers.overlay = .vegetation
        // iPad Pro 12.9 landscape, search card short (a top push), ornaments below
        let map = map(CGSize(width: 1366, height: 1024), content: UIEdgeInsets(top: 24, left: 0, bottom: 28, right: 0))
        let framing = UIEdgeInsets(top: 116, left: 0, bottom: 76, right: 80)
        let insets = SpotlightPresenter.insets(framing: framing)
        let free = map.bounds.inset(by: insets)
        func show(_ code: String) throws {
            model.showOnMap(code)
            let s = try #require(model.spotlight)
            let target = MapCamera.fit(s.bounds(aspect: Double(free.width / free.height)), maxZoom: s.maxZoom, insets: insets, in: map)
            MapCamera().move(map, to: target, insets: insets, duration: 0)
        }
        func visible(_ lon: Double, _ lat: Double) -> Bool {
            free.contains(map.convert(CLLocationCoordinate2D(latitude: lat, longitude: lon), toPointTo: map))
        }
        try show("DOB")
        #expect(visible(147.33, -43.45), "South Bruny (Adventure Bay)")
        #expect(visible(146.98, -43.42), "the far south Huon (Southport)")
        try show("DMO")
        let dmo = try #require(model.spotlight)
        for patch in dmo.patches { #expect(visible(patch.p[0], patch.p[1]), "\(patch.p)") }
    }

    /// Finding 9: a camera read after a padded flight is relative to that
    /// padding; restoring it with the remembered padding lands exactly back.
    @Test func restoringASavedCameraUsesItsPadding() {
        let map = map(CGSize(width: 390, height: 844), content: UIEdgeInsets(top: 47, left: 0, bottom: 120, right: 0))
        let director = MapCamera()
        let lopsided = UIEdgeInsets(top: 300, left: 10, bottom: 130, right: 120)
        let first = MapCamera.fit([147.0, -42.0, 147.2, -41.9], maxZoom: 15, insets: lopsided, in: map)
        director.move(map, to: first, insets: lopsided, duration: 0)
        let anchor = CLLocationCoordinate2D(latitude: -41.95, longitude: 147.1)
        let before = map.convert(anchor, toPointTo: map)
        let saved = director.save(map)
        let elsewhere = MapCamera.fit([145.0, -43.0, 146.0, -42.0], maxZoom: 15, insets: .zero, in: map)
        director.move(map, to: elsewhere, insets: nil, duration: 0)
        director.restore(map, to: saved, duration: 0)
        let after = map.convert(anchor, toPointTo: map)
        #expect(abs(after.x - before.x) < 1 && abs(after.y - before.y) < 1, "\(before) → \(after)")
    }

    /// Finding 12: a delayed flight is dropped when she touches the map.
    @Test func aGestureCancelsAPendingFlight() async throws {
        let director = MapCamera()
        var flew = false
        director.schedule(after: 0.05) { flew = true }
        director.gestureBegan()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!flew)
        director.schedule(after: 0.01) { flew = true }
        try await Task.sleep(for: .milliseconds(150))
        #expect(flew)
    }
}

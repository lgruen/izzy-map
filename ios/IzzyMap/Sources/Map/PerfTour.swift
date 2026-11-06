#if DEBUG
import MapLibre
import os
import QuartzCore
import UIKit

/// DEBUG `-perfTour YES`: once the map first settles, a scripted camera
/// tour (zoom out/in over the level switches, pans) while every frame's
/// MapLibre stats and the display link's frame intervals are recorded; the
/// summary goes to the log (category "Perf") and to `perf-tour.json` in the
/// app's tmp directory. Compares raster tile sizes (`-rasterTileSize`).
@MainActor
final class PerfTour {
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Perf")
    static let enabled = UserDefaults.standard.bool(forKey: "perfTour")

    private var started = false
    private var recording = false
    private var encode: [Double] = []
    private var render: [Double] = []
    private var intervals: [Double] = []
    private var maxTextures = 0, maxTextureBytes = 0, maxDrawCalls = 0
    private var lastTextures = 0, lastTextureBytes = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var tourStart: CFTimeInterval = 0

    func frame(_ stats: MLNRenderingStats) {
        guard recording else { return }
        encode.append(stats.encodingTime * 1000)
        render.append(stats.renderingTime * 1000)
        maxTextures = max(maxTextures, Int(stats.numActiveTextures))
        maxTextureBytes = max(maxTextureBytes, Int(stats.memTextures))
        maxDrawCalls = max(maxDrawCalls, Int(stats.numDrawCalls))
        lastTextures = Int(stats.numActiveTextures)
        lastTextureBytes = Int(stats.memTextures)
    }

    /// Starts once, on the first idle.
    func idle(_ map: MLNMapView) {
        guard Self.enabled, !started else { return }
        started = true
        let center = map.centerCoordinate, zoom = map.zoomLevel
        // pinch out/in across two level switches, pan ~2 screens, back
        let east = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + 0.03)
        let north = CLLocationCoordinate2D(latitude: center.latitude + 0.02, longitude: center.longitude + 0.03)
        let steps: [(CLLocationCoordinate2D, Double, TimeInterval)] = [
            (center, zoom - 2.2, 3), (center, zoom, 3),
            (east, zoom, 2), (north, zoom, 2),
            (north, zoom - 1.3, 2), (center, zoom - 1.3, 2.5), (center, zoom, 2),
            (center, zoom - 2.2, 3), (center, zoom, 3),
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            recording = true
            tourStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            run(steps[...], on: map)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last = lastTimestamp { intervals.append((link.timestamp - last) * 1000) }
        lastTimestamp = link.timestamp
    }

    private func run(_ steps: ArraySlice<(CLLocationCoordinate2D, Double, TimeInterval)>, on map: MLNMapView) {
        guard let (target, zoom, duration) = steps.first else { return finish(map) }
        let camera = MLNMapCamera(lookingAtCenter: target, altitude: 0, pitch: 0, heading: 0)
        camera.altitude = MLNAltitudeForZoomLevel(zoom, 0, target.latitude, map.bounds.size)
        map.setCamera(camera, withDuration: duration,
                      animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut)) { [self] in
            run(steps.dropFirst(), on: map)
        }
    }

    private func finish(_ map: MLNMapView) {
        // let the last tiles land, then sample the resting texture set
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            recording = false
            link?.invalidate()
            func pct(_ a: [Double], _ p: Double) -> Double {
                guard !a.isEmpty else { return 0 }
                let s = a.sorted()
                return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
            }
            func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
            let hitches = intervals.filter { $0 > 25 }.count
            let summary: [String: Any] = [
                "tileSize": StyleBuilder.tileSize(.tasmap),
                "seconds": CACurrentMediaTime() - tourStart,
                "frames": encode.count,
                "displayFrames": intervals.count,
                "encodeMsMean": mean(encode), "encodeMsP50": pct(encode, 0.5),
                "encodeMsP95": pct(encode, 0.95), "encodeMsP99": pct(encode, 0.99), "encodeMsMax": pct(encode, 1),
                "presentMsMean": mean(render), "presentMsP95": pct(render, 0.95),
                "intervalMsP50": pct(intervals, 0.5), "intervalMsP95": pct(intervals, 0.95),
                "intervalMsP99": pct(intervals, 0.99), "intervalMsMax": pct(intervals, 1),
                "intervalsOver25ms": hitches,
                "maxActiveTextures": maxTextures, "maxTextureMB": Double(maxTextureBytes) / 1_048_576,
                "restActiveTextures": lastTextures, "restTextureMB": Double(lastTextureBytes) / 1_048_576,
                "maxDrawCalls": maxDrawCalls,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "perf-tour.json"))
            Self.logger.notice("perf tour \(text, privacy: .public)")
        }
    }
}
#endif

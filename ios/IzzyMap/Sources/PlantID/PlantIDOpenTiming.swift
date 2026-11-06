import Foundation
import os
import QuartzCore

/// How long Identify takes to appear: the tap on the leaf button → the
/// first frame drawn with the sheet in it. An os_signpost interval
/// "IdentifyOpen" (Instruments: Points of Interest / os_signpost, category
/// PlantID) plus the last value in Diagnostics, for the device.
@MainActor
enum PlantIDOpenTiming {
    private static let signposter = OSSignposter(subsystem: "org.gruenschloss.izzymap", category: "PlantID")
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")
    nonisolated private static let lastKey = "plantIDOpenLast"
    private static var pending: (start: ContinuousClock.Instant, state: OSSignpostIntervalState)?
    private static var appearedAt: Duration?
    private static var link: CADisplayLink?

    /// The tap (AppModel.present(.plantID)).
    static func begin() {
        if let pending { signposter.endInterval("IdentifyOpen", pending.state, "superseded") }
        pending = (.now, signposter.beginInterval("IdentifyOpen", id: signposter.makeSignpostID()))
        appearedAt = nil
    }

    /// Identify's view appeared (its body has been built): the frame it is
    /// in reaches the screen at the next display refresh.
    static func appeared() {
        guard let pending, appearedAt == nil else { return }
        appearedAt = pending.start.duration(to: .now)
        signposter.emitEvent("IdentifyAppeared")
        link?.invalidate()
        let target = LinkTarget()
        let l = CADisplayLink(target: target, selector: #selector(LinkTarget.tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate static func firstFrame() {
        link?.invalidate()
        link = nil
        guard let pending else { return }
        self.pending = nil
        let took = pending.start.duration(to: .now)
        signposter.endInterval("IdentifyOpen", pending.state)
        let ms = { (d: Duration) in Int((d / .milliseconds(1)).rounded()) }
        let line = "\(ms(took)) ms to the first frame (view appeared at \(appearedAt.map(ms) ?? -1) ms) · \(Date.now.formatted(.iso8601))"
        logger.info("Identify opened: \(line, privacy: .public)")
        UserDefaults.standard.set(line, forKey: lastKey)
    }

    /// The last measured open (Diagnostics).
    nonisolated static var lastLine: String? { UserDefaults.standard.string(forKey: lastKey) }

    private final class LinkTarget: NSObject {
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { PlantIDOpenTiming.firstFrame() } }
    }
}

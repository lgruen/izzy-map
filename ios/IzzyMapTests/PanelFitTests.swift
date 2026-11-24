import CoreGraphics
import Testing
@testable import IzzyMap

/// The phone sheet's fitted detent is a function of its glance content
/// alone. It used to subtract the sheet's bottom safe area, which the
/// system sets from the sheet's own height — with the "No offline maps"
/// row that never settled (133 → 115 → 99 → 133 pt) and the glance came to
/// rest at a different height after a card than at launch.
struct PanelFitTests {
    /// iPhone 16e at the default text size: the search header alone (80),
    /// with the notice row below it (78 + 55), with a pin card's glance
    /// (78 + 188 + 12; the card runs on below it).
    @Test func glanceHeights() {
        #expect(GlanceFit(header: 80).height == 80)
        #expect(GlanceFit(header: 78, content: 55).height == 133)
        #expect(GlanceFit(header: 78, content: 577, peek: 188, hasCard: true).height == 278)
        // a card shorter than its glance mark: all of it
        #expect(GlanceFit(header: 78, content: 150, peek: 188, hasCard: true).height == 228)
        // a stale glance mark once the card has gone counts for nothing
        #expect(GlanceFit(header: 78, content: 55, peek: 188, hasCard: false).height == 133)
        #expect(GlanceFit(header: 0).height == 44)
    }

    /// The bottom band the system gives a sheet resting on a detent, as
    /// measured on the iPhone 16e (fixed detents, default text size): 0
    /// while it floats (up to 99 pt), 34 once it reaches the home indicator
    /// (from 105 pt; 18 and 28 seen on the way).
    private static func band(forDetent detent: CGFloat) -> CGFloat { detent <= 99 ? 0 : 34 }

    /// The loop the sheet runs: a detent → the system's band for it → the
    /// band measured back into the glance → the next detent. It must hold
    /// from the first step, for each glance and whatever band arrives.
    @Test(arguments: [
        GlanceFit(header: 80), GlanceFit(header: 78, content: 55),
        GlanceFit(header: 78, content: 577, peek: 188, hasCard: true),
        GlanceFit(header: 120, content: 160),   // a large text size
    ])
    func idempotentUnderTheSheetsOwnBand(start: GlanceFit) {
        var glance = start
        let first = glance.height
        for _ in 0 ..< 4 {
            glance.bottomInset = Self.band(forDetent: glance.height)
            #expect(glance.height == first)
        }
        for band in [0, 18, 28, 34] as [CGFloat] {
            glance.bottomInset = band
            #expect(glance.height == first)
        }
    }
}

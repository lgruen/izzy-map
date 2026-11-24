import CoreGraphics
import Testing
@testable import IzzyMap

/// The phone sheet's fitted detent is a function of its glance content
/// alone. It used to subtract the sheet's bottom safe area, which the
/// system sets from the sheet's own height (iPhone 16e: 0 while the small
/// sheet floats, 18 and 28 on the way, 34 once it reaches the home
/// indicator) — with the "No offline maps" row that never settled
/// (133 → 115 → 99 → 133 pt) and the glance came to rest at a different
/// height after a card than at launch.
struct PanelFitTests {
    /// iPhone 16e at the default text size: the search header alone (80),
    /// with the notice row below it (78 + 55), with a pin card's glance
    /// (78 + 188 + 12; the card runs on below it).
    @Test func glanceHeights() {
        #expect(CompactPanelSheet.fitHeight(header: 80, content: 0, peek: 0) == 80)
        #expect(CompactPanelSheet.fitHeight(header: 78, content: 55, peek: 0) == 133)
        #expect(CompactPanelSheet.fitHeight(header: 78, content: 577, peek: 188) == 278)
        // a card shorter than its glance mark: all of it
        #expect(CompactPanelSheet.fitHeight(header: 78, content: 150, peek: 188) == 228)
        #expect(CompactPanelSheet.fitHeight(header: 0, content: 0, peek: 0) == 44)
    }

    /// The sheet's response to a detent — whatever bottom band the system
    /// then gives the sheet — changes nothing the fit reads: the next
    /// computation returns the same detent, so the sheet moves once per
    /// content change.
    @Test(arguments: [0, 18, 28, 34] as [CGFloat])
    func idempotentWhateverTheSheetsBottomBand(band: CGFloat) {
        struct Glance { var header: CGFloat; var content: CGFloat; var peek: CGFloat }
        for glance in [Glance(header: 80, content: 0, peek: 0), Glance(header: 78, content: 55, peek: 0),
                       Glance(header: 78, content: 577, peek: 188)] {
            let first = CompactPanelSheet.fitHeight(header: glance.header, content: glance.content, peek: glance.peek)
            var detent = first
            // the sheet settles on `detent` with `band` below it; what the
            // glance measures is its own content, unchanged
            for _ in 0 ..< 3 {
                let sheetHeight = detent + band
                #expect(sheetHeight >= first)
                detent = CompactPanelSheet.fitHeight(header: glance.header, content: glance.content, peek: glance.peek)
                #expect(detent == first)
            }
        }
    }
}

import Foundation
import Testing

/// The app's half of the rotation UI tests (LaunchTests), which skip where
/// a simulator never turns: an iPhone must be allowed to go landscape, or
/// the sheet ↔ card layout switch (and its modal reset,
/// `WindowModelTests.aLayoutSwitchResetsTheModal`) never happens on a phone.
struct OrientationTests {
    /// The built Info.plist as written (XcodeGen's
    /// `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` becomes the
    /// `~iphone` key), read raw so the device-suffix lookup can't hide it.
    private static func supported(_ device: String) throws -> Set<String> {
        let url = Bundle.main.bundleURL.appending(path: "Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any], "the host app's Info.plist")
        #expect(plist["CFBundleIdentifier"] as? String == "org.gruenschloss.izzymap", "hosted in the app")
        let values = plist["UISupportedInterfaceOrientations~\(device)"] ?? plist["UISupportedInterfaceOrientations"]
        return Set(try #require(values as? [String], "supported orientations for \(device)"))
    }

    @Test func iPhoneTurnsLandscapeBothWays() throws {
        let phone = try Self.supported("iphone")
        #expect(phone.contains("UIInterfaceOrientationPortrait"))
        #expect(phone.contains("UIInterfaceOrientationLandscapeLeft"))
        #expect(phone.contains("UIInterfaceOrientationLandscapeRight"))
    }

    @Test func iPadAllowsEveryOrientation() throws {
        // iPad multitasking (Split View, Stage Manager) needs all four
        #expect(try Self.supported("ipad") == [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        ])
    }
}

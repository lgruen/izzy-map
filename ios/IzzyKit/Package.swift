// swift-tools-version: 6.2
// IzzyKit: everything in IzzyMap that needs no UI (data tables, search,
// grid references, plant lists, plant-ID scoring, download rules).
// `swift test` runs on the Mac without a simulator.
import PackageDescription

let package = Package(
    name: "IzzyKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "IzzyKit", targets: ["IzzyKit"])],
    targets: [
        .target(name: "IzzyKit"),
        .testTarget(name: "IzzyKitTests", dependencies: ["IzzyKit"]),
    ]
)

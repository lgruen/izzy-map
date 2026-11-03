import Foundation
import Testing
@testable import IzzyKit

/// Where the tests read the REAL bundled data: the app's resource folder
/// (ios/IzzyMap/Resources/Data, written by pipeline/build_*.py).
enum TestData {
    static let package = URL(filePath: #filePath)   // …/ios/IzzyKit/Tests/IzzyKitTests/TestData.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let root = package.deletingLastPathComponent().appending(path: "IzzyMap/Resources/Data")
    static let data = BundledData(root: root)
    /// Generated fixtures (see Tests/Fixtures/make_*.{mjs,ts}).
    static let fixtures = package.appending(path: "Tests/Fixtures")

    static func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtures.appending(path: name)))
    }
    /// Decoded once per test process (the catalog is the expensive one).
    private static let catalogResult = Result { try data.plantCatalog() }
    static func catalog() throws -> PlantCatalog { try catalogResult.get() }
}

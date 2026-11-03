import Foundation
import Testing
@testable import IzzyKit

struct MGAFixture: Decodable { var name: String; var lat: Double; var lon: Double; var e: Double; var n: Double }

@Suite struct GridReferenceTests {
    static let points: [MGAFixture] = try! TestData.fixture("mga.json")

    @Test(arguments: points.map(\.name))
    func agreesWithWebProj4WithinOneCentimetre(_ name: String) throws {
        let f = try #require(Self.points.first { $0.name == name })
        let p = MGA55Point(latitude: f.lat, longitude: f.lon)
        #expect(abs(p.easting - f.e) <= 0.01, "easting off by \(p.easting - f.e) m")
        #expect(abs(p.northing - f.n) <= 0.01, "northing off by \(p.northing - f.n) m")
    }

    @Test func centralMeridianIsFalseEasting() {
        #expect(MGA55Point(latitude: -42, longitude: 147).easting == 500_000)
    }

    @Test func readoutStrings() {
        #expect(GridReadout.mga.text(latitude: -42.88234, longitude: 147.3272) == "MGA55 526720E 5252199N")
        #expect(GridReadout.latLon.text(latitude: -42.88234, longitude: 147.3272) == "-42.88234, 147.32720")
        #expect(GridReadout.mga.toggled == .latLon)
        #expect(GridReadout.latLon.toggled == .mga)
        #expect(GridReadout.mga.spokenText(latitude: -42.88234, longitude: 147.3272)
            == "Map centre, MGA zone 55, easting 526720, northing 5252199")
        #expect(GridReadout.latLon.spokenText(latitude: -42.88234, longitude: 147.3272)
            == "Map centre, latitude -42.88234, longitude 147.32720")
    }

    /// Pasteable whatever the region format: no grouping, "." decimal, ASCII digits.
    @Test func readoutIgnoresTheDeviceLocale() {
        let text = GridReadout.latLon.text(latitude: -41.123456, longitude: 146.5)
        #expect(text == "-41.12346, 146.50000")
        #expect(GridReadout.mga.text(latitude: -41.0, longitude: 145.0).allSatisfy { $0.isASCII })
        #expect(!GridReadout.mga.text(latitude: -41.0, longitude: 145.0).contains(","))
    }
}

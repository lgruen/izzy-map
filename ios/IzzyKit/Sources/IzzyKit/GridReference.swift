import Foundation

/// A GDA94 / MGA zone 55 (EPSG:28355) grid position in metres.
public struct MGA55Point: Sendable, Hashable {
    public var easting: Double
    public var northing: Double
    public init(easting: Double, northing: Double) {
        self.easting = easting
        self.northing = northing
    }

    /// Projects latitude/longitude (degrees) onto MGA zone 55. GPS gives
    /// WGS84 and MGA is GDA94; the ~1.8 m datum difference is ignored by
    /// design (as in the web app and LISTmap's own readout). Points west of
    /// 144°E (King Island) are projected into zone 55 regardless, like
    /// LISTmap does.
    public init(latitude: Double, longitude: Double) {
        self = TransverseMercator.mga55.project(latitude: latitude, longitude: longitude)
    }
}

/// Transverse Mercator via Krüger's n-series to order n⁶ (Karney 2011,
/// "Transverse Mercator with an accuracy of a few nanometres"): far below
/// a millimetre anywhere in a 6° UTM zone, so no proj library is needed.
struct TransverseMercator: Sendable {
    let k0: Double, falseEasting: Double, falseNorthing: Double, lon0: Double
    let e: Double, A: Double, alpha: [Double]

    init(a: Double, inverseFlattening: Double, k0: Double, lon0: Double,
         falseEasting: Double, falseNorthing: Double) {
        let f = 1 / inverseFlattening
        let n = f / (2 - f)
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        self.k0 = k0
        self.lon0 = lon0
        self.falseEasting = falseEasting
        self.falseNorthing = falseNorthing
        e = (f * (2 - f)).squareRoot()
        // rectifying radius: meridian arc length = A · rectifying latitude
        A = a / (1 + n) * (1 + n2 / 4 + n4 / 64 + n6 / 256)
        alpha = [
            n / 2 - 2 * n2 / 3 + 5 * n3 / 16 + 41 * n4 / 180 - 127 * n5 / 288 + 7891 * n6 / 37800,
            13 * n2 / 48 - 3 * n3 / 5 + 557 * n4 / 1440 + 281 * n5 / 630 - 1983433 * n6 / 1935360,
            61 * n3 / 240 - 103 * n4 / 140 + 15061 * n5 / 26880 + 167603 * n6 / 181440,
            49561 * n4 / 161280 - 179 * n5 / 168 + 6601661 * n6 / 7257600,
            34729 * n5 / 80640 - 3418889 * n6 / 1995840,
            212378941 * n6 / 319334400,
        ]
    }

    /// GRS80, UTM zone 55 south (central meridian 147°E).
    static let mga55 = TransverseMercator(
        a: 6_378_137, inverseFlattening: 298.257222101, k0: 0.9996, lon0: 147,
        falseEasting: 500_000, falseNorthing: 10_000_000)

    func project(latitude: Double, longitude: Double) -> MGA55Point {
        let phi = latitude * .pi / 180
        let lam = (longitude - lon0) * .pi / 180
        // tan of the conformal latitude, then Gauss–Schreiber (spherical TM)
        let s = sin(phi)
        let t = sinh(atanh(s) - e * atanh(e * s))
        let xi = atan2(t, cos(lam))
        let eta = atanh(sin(lam) / (1 + t * t).squareRoot())
        // Krüger's series maps the sphere's TM onto the ellipsoid's
        var x = eta, y = xi
        for (j, a) in alpha.enumerated() {
            let k = 2 * Double(j + 1)
            x += a * cos(k * xi) * sinh(k * eta)
            y += a * sin(k * xi) * cosh(k * eta)
        }
        return MGA55Point(easting: falseEasting + k0 * A * x, northing: falseNorthing + k0 * A * y)
    }
}

/// The map-centre readout pill: MGA55 grid reference or lat/lon (a tap toggles).
///
/// Locale-independent on purpose (POSIX digits, no grouping, "." decimal):
/// the text is meant to be pasted into LISTmap or a GPS, whatever the
/// device's region format.
public enum GridReadout: Sendable, Hashable {
    case mga
    case latLon

    /// The other style (what a tap on the pill switches to).
    public var toggled: GridReadout { self == .mga ? .latLon : .mga }

    /// "MGA55 526720E 5252199N" (whole metres) or "-42.88234, 147.32720"
    /// (5 dp, ≈ 1 m).
    public func text(latitude: Double, longitude: Double) -> String {
        switch self {
        case .mga:
            let (e, n) = Self.metres(latitude: latitude, longitude: longitude)
            return "MGA55 \(e)E \(n)N"
        case .latLon:
            return "\(Self.degrees(latitude)), \(Self.degrees(longitude))"
        }
    }

    /// What VoiceOver reads for the pill (same figures, words for the units).
    public func spokenText(latitude: Double, longitude: Double) -> String {
        switch self {
        case .mga:
            let (e, n) = Self.metres(latitude: latitude, longitude: longitude)
            return "Map centre, MGA zone 55, easting \(e), northing \(n)"
        case .latLon:
            return "Map centre, latitude \(Self.degrees(latitude)), longitude \(Self.degrees(longitude))"
        }
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Whole metres, rounded half away from zero; plain ASCII digits.
    private static func metres(latitude: Double, longitude: Double) -> (String, String) {
        let p = MGA55Point(latitude: latitude, longitude: longitude)
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)
            .grouping(.never).locale(posix)
        return (p.easting.formatted(style), p.northing.formatted(style))
    }

    private static func degrees(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(5)).grouping(.never).locale(posix))
    }
}

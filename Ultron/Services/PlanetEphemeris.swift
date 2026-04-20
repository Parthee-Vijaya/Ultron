import Foundation

/// Which bright planet a `PlanetVisibility` row refers to. Keyed so the
/// view can pick a glyph / color without string-matching.
enum PlanetKind: String, Sendable, CaseIterable {
    case mercury, venus, mars, jupiter, saturn

    var danishName: String {
        switch self {
        case .mercury: return "Merkur"
        case .venus:   return "Venus"
        case .mars:    return "Mars"
        case .jupiter: return "Jupiter"
        case .saturn:  return "Saturn"
        }
    }

    /// Loose magnitude estimate for "is it worth calling out". Real
    /// magnitudes vary with phase/distance; these are defensible averages
    /// that we use for sort order only.
    fileprivate var nominalMagnitude: Double {
        switch self {
        case .venus:   return -4.0
        case .jupiter: return -2.0
        case .mars:    return 0.0
        case .mercury: return 0.5
        case .saturn:  return 0.8
        }
    }

    /// Approximate glyph — emoji where available, ASCII fallback.
    var glyph: String {
        switch self {
        case .mercury: return "☿"
        case .venus:   return "♀"
        case .mars:    return "♂"
        case .jupiter: return "♃"
        case .saturn:  return "♄"
        }
    }
}

/// A planet above the user's horizon at the current moment, with enough
/// info for the Cockpit Himmel tile to render one line per planet.
struct PlanetVisibility: Identifiable, Sendable, Equatable {
    let kind: PlanetKind
    let altitudeDeg: Double        // 0 = horizon, 90 = zenith
    let azimuthDeg: Double          // 0 = N, 90 = E, 180 = S, 270 = W
    let magnitude: Double           // nominal; used for sort order only
    var id: String { kind.rawValue }
    var compass: String { Compass.label(for: azimuthDeg) }
}

/// Pure-local approximate ephemeris for the five naked-eye planets using
/// NASA-JPL "Approximate Positions of the Planets" mean orbital elements +
/// linear drift. Accurate to fractions of a degree across 1800-2050 —
/// plenty for a "which planet is visible tonight" tile.
///
/// Reference: https://ssd.jpl.nasa.gov/planets/approx_pos.html
enum PlanetEphemeris {
    /// Return planets currently above the user's horizon (altitude > 10°)
    /// sorted so the brightest planets float to the top. Evaluated at
    /// `now` for a user standing at (latitude, longitude).
    static func visiblePlanets(
        latitude: Double,
        longitude: Double,
        at now: Date = Date()
    ) -> [PlanetVisibility] {
        let jd = julianDate(from: now)
        let T = (jd - 2_451_545.0) / 36_525.0  // centuries from J2000
        let earth = heliocentricEcliptic(for: .earth, T: T)

        var output: [PlanetVisibility] = []
        for kind in PlanetKind.allCases {
            let planet = heliocentricEcliptic(for: .fromKind(kind), T: T)
            let geo = Vec3(x: planet.x - earth.x,
                           y: planet.y - earth.y,
                           z: planet.z - earth.z)
            let (ra, dec) = eclipticToEquatorial(geo, T: T)
            let (alt, az) = equatorialToHorizontal(
                raRadians: ra,
                decRadians: dec,
                latitude: latitude,
                longitude: longitude,
                at: now
            )
            let altDeg = alt * 180 / .pi
            let azDeg  = (az * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            guard altDeg > 10 else { continue }
            output.append(PlanetVisibility(
                kind: kind,
                altitudeDeg: altDeg,
                azimuthDeg: azDeg,
                magnitude: kind.nominalMagnitude
            ))
        }
        // Brightest (lowest magnitude) first.
        return output.sorted { $0.magnitude < $1.magnitude }
    }

    // MARK: - Internals

    private struct Vec3 { var x, y, z: Double }

    /// Identifies an orbit to evaluate — Earth is needed as a reference to
    /// turn heliocentric coords into geocentric.
    private enum OrbitBody {
        case mercury, venus, earth, mars, jupiter, saturn
        static func fromKind(_ kind: PlanetKind) -> OrbitBody {
            switch kind {
            case .mercury: return .mercury
            case .venus:   return .venus
            case .mars:    return .mars
            case .jupiter: return .jupiter
            case .saturn:  return .saturn
            }
        }
    }

    /// J2000 mean orbital elements + linear rates per century. Columns:
    /// a (AU), e, I (deg), L (deg, mean longitude), ϖ (deg, longitude of
    /// perihelion), Ω (deg, longitude of ascending node). Rates are in the
    /// same units per Julian century.
    private static let elements: [OrbitBody: (base: [Double], rate: [Double])] = [
        .mercury: (
            base: [0.387_099_27, 0.205_635_93,  7.004_97,   252.250_324_70,  77.457_796_62,  48.330_535_28],
            rate: [0.000_000_37, 0.000_019_06, -0.005_94, 149_472.674_110_91,  0.160_472_00, -0.125_340_81]
        ),
        .venus: (
            base: [0.723_336_60, 0.006_773_23,  3.394_67,   181.979_801_00, 131.602_467_00,  76.679_841_00],
            rate: [0.000_000_39,-0.000_047_77, -0.000_856, 58_517.815_618_10,  0.000_537_00, -0.278_442_00]
        ),
        .earth: (
            base: [1.000_002_61, 0.016_711_23, -0.000_015,  100.464_572_33, 102.937_619_37,   0.0],
            rate: [0.000_005_62,-0.000_043_92, -0.013_296, 35_999.372_442_30,  0.323_273_64,   0.0]
        ),
        .mars: (
            base: [1.523_710_34, 0.093_394_10,  1.849_76,   -4.553_432_05, -23.943_629_07,  49.559_538_29],
            rate: [0.000_018_47, 0.000_079_82, -0.008_131, 19_140.301_687_90,  0.445_943_51, -0.295_646_57]
        ),
        .jupiter: (
            base: [5.202_887_00,-0.048_386_24, 1.303_270_00,  34.396_441_00, 14.728_479_00, 100.473_909_09],
            rate: [-0.001_161_07, -0.000_132_53,-0.001_984_00,  3_034.746_122_00,  0.213_253_14,  0.206_469_42]
        ),
        .saturn: (
            base: [9.536_675_94,  0.055_862_86, 2.488_878_00,  49.954_243_00, 92.598_878_00, 113.662_423_25],
            rate: [-0.001_259_41,-0.000_509_91, 0.001_930_00,  1_222.493_622_00,-0.419_082_44, -0.285_161_93]
        )
    ]

    private static func heliocentricEcliptic(for body: OrbitBody, T: Double) -> Vec3 {
        guard let e = elements[body] else { return Vec3(x: 0, y: 0, z: 0) }
        let a       = e.base[0] + e.rate[0] * T            // AU
        let ecc     = e.base[1] + e.rate[1] * T
        let inc     = (e.base[2] + e.rate[2] * T) * .pi / 180
        let L       = (e.base[3] + e.rate[3] * T) * .pi / 180
        let lonPeri = (e.base[4] + e.rate[4] * T) * .pi / 180
        let omegaN  = (e.base[5] + e.rate[5] * T) * .pi / 180

        let argPeri = lonPeri - omegaN
        let M = normalizeAngle(L - lonPeri)

        // Solve Kepler's equation: E - e·sin E = M. Newton–Raphson, 6 iterations.
        var E = M + ecc * sin(M) * (1 + ecc * cos(M))
        for _ in 0..<6 {
            let delta = (E - ecc * sin(E) - M) / (1 - ecc * cos(E))
            E -= delta
            if abs(delta) < 1e-10 { break }
        }

        let xPrime = a * (cos(E) - ecc)
        let yPrime = a * sqrt(max(0, 1 - ecc * ecc)) * sin(E)

        // Rotate orbital plane → heliocentric ecliptic XYZ.
        let cosArg = cos(argPeri), sinArg = sin(argPeri)
        let cosOmg = cos(omegaN),  sinOmg = sin(omegaN)
        let cosInc = cos(inc)

        let x = (cosArg * cosOmg - sinArg * sinOmg * cosInc) * xPrime
              + (-sinArg * cosOmg - cosArg * sinOmg * cosInc) * yPrime
        let y = (cosArg * sinOmg + sinArg * cosOmg * cosInc) * xPrime
              + (-sinArg * sinOmg + cosArg * cosOmg * cosInc) * yPrime
        let z = (sinArg * sin(inc)) * xPrime
              + (cosArg * sin(inc)) * yPrime

        return Vec3(x: x, y: y, z: z)
    }

    /// Ecliptic XYZ → equatorial (RA, Dec). Obliquity tracks slowly with T.
    private static func eclipticToEquatorial(_ v: Vec3, T: Double) -> (ra: Double, dec: Double) {
        let obliquity = (23.439_291 - 0.013_004_2 * T) * .pi / 180
        let x = v.x
        let y = v.y * cos(obliquity) - v.z * sin(obliquity)
        let z = v.y * sin(obliquity) + v.z * cos(obliquity)
        let ra  = atan2(y, x)
        let dec = atan2(z, sqrt(x * x + y * y))
        return (ra, dec)
    }

    /// Equatorial (RA/Dec) → local horizontal (altitude, azimuth). Uses
    /// Greenwich Mean Sidereal Time + longitude for the hour angle.
    private static func equatorialToHorizontal(
        raRadians: Double,
        decRadians: Double,
        latitude: Double,
        longitude: Double,
        at now: Date
    ) -> (altitude: Double, azimuth: Double) {
        let gmst = greenwichMeanSiderealTime(for: now)
        let lst = gmst + longitude * .pi / 180
        let hourAngle = lst - raRadians
        let latRad = latitude * .pi / 180

        let sinAlt = sin(decRadians) * sin(latRad)
                   + cos(decRadians) * cos(latRad) * cos(hourAngle)
        let alt = asin(max(-1, min(1, sinAlt)))

        let cosAz = (sin(decRadians) - sin(alt) * sin(latRad)) / (cos(alt) * cos(latRad))
        let sinAz = -cos(decRadians) * sin(hourAngle) / cos(alt)
        let az = atan2(sinAz, cosAz)
        return (alt, az)
    }

    /// GMST in radians. Meeus §12.
    private static func greenwichMeanSiderealTime(for date: Date) -> Double {
        let jd = julianDate(from: date)
        let T = (jd - 2_451_545.0) / 36_525.0
        // Degrees at 0h UT + fractional day.
        let theta = 280.460_618_37
                  + 360.985_647_366_29 * (jd - 2_451_545.0)
                  + 0.000_387_933 * T * T
                  - (T * T * T) / 38_710_000
        let mod = (theta.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return mod * .pi / 180
    }

    /// Julian Date at the given instant (UT).
    private static func julianDate(from date: Date) -> Double {
        // Unix epoch = JD 2440587.5.
        return 2_440_587.5 + date.timeIntervalSince1970 / 86_400
    }

    /// Normalize angle into [-π, π].
    private static func normalizeAngle(_ a: Double) -> Double {
        var v = a.truncatingRemainder(dividingBy: 2 * .pi)
        if v > .pi { v -= 2 * .pi }
        if v < -.pi { v += 2 * .pi }
        return v
    }
}

import CoreLocation
import Foundation

/// Open-Meteo air-quality client — free, no API key, same provider as
/// `WeatherService`. Docs: https://open-meteo.com/en/docs/air-quality-api
struct AirQualitySnapshot: Codable, Equatable {
    /// European AQI (0–100 scale — 0 great, 100 very poor).
    let europeanAQI: Int?
    /// UV index at the current hour (0–11+).
    let uvIndex: Double?
    /// Fine particulate matter (µg/m³).
    let pm25: Double?
    /// Larger particulate matter (µg/m³).
    let pm10: Double?
    let fetchedAt: Date

    enum AQIBand: String {
        case excellent, good, moderate, poor, veryPoor, extreme, unknown

        var label: String {
            switch self {
            case .excellent: return "Fremragende"
            case .good:      return "God"
            case .moderate:  return "Moderat"
            case .poor:      return "Ringe"
            case .veryPoor:  return "Meget ringe"
            case .extreme:   return "Ekstrem"
            case .unknown:   return "—"
            }
        }
    }

    var aqiBand: AQIBand {
        guard let aqi = europeanAQI else { return .unknown }
        switch aqi {
        case ..<20: return .excellent
        case 20..<40: return .good
        case 40..<60: return .moderate
        case 60..<80: return .poor
        case 80..<100: return .veryPoor
        default: return .extreme
        }
    }

    enum UVBand: String {
        case low, moderate, high, veryHigh, extreme, unknown

        var label: String {
            switch self {
            case .low:      return "Lav"
            case .moderate: return "Moderat"
            case .high:     return "Høj"
            case .veryHigh: return "Meget høj"
            case .extreme:  return "Ekstrem"
            case .unknown:  return "—"
            }
        }
    }

    var uvBand: UVBand {
        guard let uv = uvIndex else { return .unknown }
        switch uv {
        case ..<3:  return .low
        case 3..<6: return .moderate
        case 6..<8: return .high
        case 8..<11: return .veryHigh
        default: return .extreme
        }
    }
}

enum AirQualityServiceError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Air-quality API returned an invalid response"
        case .httpError(let code): return "Air-quality API HTTP \(code)"
        }
    }
}

final class AirQualityService {
    func fetch(for coordinate: CLLocationCoordinate2D) async throws -> AirQualitySnapshot {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "european_aqi,uv_index,pm2_5,pm10"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components.url else { throw AirQualityServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AirQualityServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AirQualityServiceError.httpError(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any] else {
            throw AirQualityServiceError.invalidResponse
        }

        return AirQualitySnapshot(
            europeanAQI: (current["european_aqi"] as? Double).map { Int($0.rounded()) }
                ?? (current["european_aqi"] as? Int),
            uvIndex: current["uv_index"] as? Double,
            pm25: current["pm2_5"] as? Double,
            pm10: current["pm10"] as? Double,
            fetchedAt: Date()
        )
    }
}

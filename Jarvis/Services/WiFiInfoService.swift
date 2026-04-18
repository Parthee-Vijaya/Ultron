import CoreWLAN
import Foundation

/// Reads the current WiFi interface state — SSID, RSSI, transmit rate.
/// On macOS 14+ `ssid()` returns nil unless the app has Location authorization.
/// We degrade gracefully — all fields are optional.
enum WiFiInfoService {
    static func current() -> WiFiInfo {
        guard let interface = CWWiFiClient.shared().interface() else {
            return WiFiInfo(ssid: nil, rssi: nil, transmitRate: nil)
        }
        let ssid = interface.ssid()
        let rssi = interface.rssiValue()
        let rate = interface.transmitRate()
        return WiFiInfo(
            ssid: ssid,
            rssi: rssi == 0 ? nil : rssi,
            transmitRate: rate <= 0 ? nil : rate
        )
    }
}

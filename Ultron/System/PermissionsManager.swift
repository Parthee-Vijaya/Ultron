import AVFoundation
import AppKit

class PermissionsManager {
    struct PermissionStatus {
        var microphone: Bool
        var accessibility: Bool
        var screenRecording: Bool
    }

    func checkAll() -> PermissionStatus {
        PermissionStatus(
            microphone: checkMicrophone(),
            accessibility: checkAccessibility(),
            screenRecording: checkScreenRecording()
        )
    }

    func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func checkAccessibility() -> Bool {
        TextInsertionService.checkAccessibilityPermission()
    }

    func checkScreenRecording() -> Bool {
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return windowList?.contains(where: { ($0["kCGWindowOwnerName"] as? String) != nil }) ?? false
    }

    func openAccessibilitySettings() {
        TextInsertionService.requestAccessibilityPermission()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

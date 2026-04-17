import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void
    let onOpenSettings: () -> Void

    @State private var micGranted = false
    @State private var accessibilityGranted = false

    private let permissions = PermissionsManager()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.accent)

            Text("Welcome to Jarvis")
                .font(.largeTitle.bold())

            Text("Your AI voice assistant for macOS.\nA few permissions are needed to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required for voice recording",
                    isGranted: micGranted,
                    action: {
                        Task {
                            micGranted = await AudioPermissionHelper.requestMicrophonePermission()
                        }
                    }
                )

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required for text insertion at cursor",
                    isGranted: accessibilityGranted,
                    action: {
                        permissions.openAccessibilitySettings()
                    }
                )
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Divider()

            HStack {
                Button("Open Settings") { onOpenSettings() }
                Spacer()
                Button("Get Started") { onComplete() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .onAppear {
            micGranted = permissions.checkMicrophone()
            accessibilityGranted = permissions.checkAccessibility()
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant") { action() }
                    .controlSize(.small)
            }
        }
    }
}

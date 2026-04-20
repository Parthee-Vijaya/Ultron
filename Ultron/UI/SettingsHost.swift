import SwiftUI

/// Small container that holds the selected-tab state for `SettingsView`. Lets
/// `AppDelegate` deep-link into a specific tab (e.g. menu bar "Hotkeys…").
@Observable
final class SettingsHostState {
    var selectedTab: SettingsTab = .apiKey
}

struct SettingsHost: View {
    @Bindable var state: SettingsHostState

    var body: some View {
        SettingsView(selectedTab: $state.selectedTab)
    }
}

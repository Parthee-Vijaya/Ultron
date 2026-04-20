import Foundation
import Observation

@Observable
class ModeManager {
    var activeMode: Mode
    private(set) var customModes: [Mode] = []
    private let customModeStore = CustomModeStore()

    var allModes: [Mode] {
        BuiltInModes.all + customModes
    }

    init() {
        activeMode = BuiltInModes.dictation
        customModes = customModeStore.loadModes()
    }

    func setActiveMode(byId id: UUID) {
        if let mode = allModes.first(where: { $0.id == id }) {
            activeMode = mode
            LoggingService.shared.log("Mode switched to: \(mode.name)")
        }
    }

    func cycleMode() {
        let modes = allModes
        guard let currentIndex = modes.firstIndex(where: { $0.id == activeMode.id }) else { return }
        let nextIndex = (currentIndex + 1) % modes.count
        activeMode = modes[nextIndex]
        LoggingService.shared.log("Mode cycled to: \(activeMode.name)")
    }

    func addCustomMode(_ mode: Mode) {
        customModes.append(mode)
        customModeStore.saveModes(customModes)
    }

    func updateCustomMode(_ mode: Mode) {
        if let index = customModes.firstIndex(where: { $0.id == mode.id }) {
            customModes[index] = mode
            customModeStore.saveModes(customModes)
            if activeMode.id == mode.id {
                activeMode = mode
            }
        }
    }

    func deleteCustomMode(id: UUID) {
        customModes.removeAll(where: { $0.id == id })
        customModeStore.saveModes(customModes)
        if activeMode.id == id {
            activeMode = BuiltInModes.dictation
        }
    }
}

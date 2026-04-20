import Foundation

/// A user-configurable "pinned" place we want commute numbers for on the
/// Cockpit's Hjem tile when no ad-hoc destination is active. Defaults cover
/// the owner's two most-frequent drives; Settings will let the user edit the
/// list in a future pass.
struct PinnedDestination: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Short display label shown in the tile header, e.g. "Vejle".
    let name: String
    /// Full geocoding-ready address handed to `CommuteService`.
    let address: String

    init(id: UUID = UUID(), name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }

    /// Seed list used until the user edits pinned destinations in Settings.
    /// Tesla-friendly driving distances from the owner's home area.
    static let defaults: [PinnedDestination] = [
        PinnedDestination(name: "Vejle", address: "Findlandsvej 2a, Vejle"),
        PinnedDestination(name: "Valby", address: "Valbygårdsvej 64, Valby, København")
    ]
}

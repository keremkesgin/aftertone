import SwiftUI

/// Where the badge + lyrics block sits on screen. Persisted the same way as
/// `LyricsSyncSettings` — a user preference that should survive a relaunch, not
/// per-session state.
enum OverlayPosition: String, CaseIterable {
    case center
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var alignment: Alignment {
        switch self {
        case .center: .center
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var displayName: String {
        switch self {
        case .center: "Center"
        case .topLeading: "Top Left"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottomTrailing: "Bottom Right"
        }
    }
}

@MainActor
final class OverlaySettings: ObservableObject {
    @Published private(set) var position: OverlayPosition

    private let defaults: UserDefaults
    private static let defaultsKey = "dev.kesgin.Turntable.overlayPosition"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultsKey), let stored = OverlayPosition(rawValue: raw) {
            position = stored
        } else {
            position = .center
        }
    }

    func set(_ position: OverlayPosition) {
        self.position = position
        defaults.set(position.rawValue, forKey: Self.defaultsKey)
    }
}

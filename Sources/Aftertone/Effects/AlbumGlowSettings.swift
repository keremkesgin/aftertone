import Foundation

/// Persisted on/off + size for `AlbumGlowView`, same pattern as the other menu-bar
/// settings: a small `@MainActor` `ObservableObject` backed by `UserDefaults`.
@MainActor
final class AlbumGlowSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    /// Multiplier on the glow blobs' diameter.
    @Published private(set) var sizeScale: Double

    static let sizeRange: ClosedRange<Double> = 0.4...2.0
    private static let sizeStep = 0.15
    private static let enabledKey = "dev.kesgin.Turntable.albumGlowEnabled"
    private static let sizeKey = "dev.kesgin.Turntable.albumGlowSizeScale"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Off by default — unlike LyricsVisibilitySettings, a first launch should not
        // show the glow until the user opts in, so `bool(forKey:)`'s natural "absent key
        // reads as false" is exactly the wanted behavior here.
        isEnabled = defaults.bool(forKey: Self.enabledKey)

        let storedSize = defaults.object(forKey: Self.sizeKey) as? Double
        // An out-of-range stored value (an older build's range, or corruption) falls
        // back to the default rather than silently clamping in a value the user never
        // actually chose.
        sizeScale = storedSize.map { Self.sizeRange.contains($0) ? $0 : 1.0 } ?? 1.0
    }

    func toggle() {
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.enabledKey)
    }

    func increaseSize() { setSize(sizeScale + Self.sizeStep) }
    func decreaseSize() { setSize(sizeScale - Self.sizeStep) }
    func resetSize() { setSize(1.0) }

    private func setSize(_ value: Double) {
        sizeScale = min(max(value, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        defaults.set(sizeScale, forKey: Self.sizeKey)
    }
}

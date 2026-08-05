import Foundation

/// Rotation speeds by RPM setting — exact values, "enthusiasts notice" (spec §7.1).
enum TurntableSpeed: String, CaseIterable, Identifiable {
    case rpm33 = "33⅓"
    case rpm45 = "45"
    case rpm78 = "78"

    var id: String { rawValue }

    var degreesPerSecond: Double {
        switch self {
        case .rpm33: return 200.0
        case .rpm45: return 270.0
        case .rpm78: return 468.0
        }
    }

    /// `degreesPerSecond` expressed as RPM, since `PlatterPhysics` models speed as RPM
    /// internally (spec §7.2's `rpm * 6` conversion).
    var rpm: Double { degreesPerSecond / 6 }
}

/// The platter's own physics — extracted from spec §7.2's `PlatterView` body so it can be
/// driven by a `TimelineView` (real use) or by synthetic frame deltas (`SelfTest`) without
/// rendering anything. A `TimelineView` per se can't be unit tested; this can.
///
/// Deliberately *not* driven by `PlaybackClock`: the platter's angle is a physical
/// consequence of motor speed, independent of playback position — spec §7.2 models it
/// with its own `rpm`/`angle` state, easing toward a target RPM rather than tracking a
/// timeline position.
final class PlatterPhysics {
    /// Seconds. Spinning up is punchier than coasting down — "platters coast" (spec §7.2).
    private let spinUpTau: TimeInterval = 0.45
    private let coastTau: TimeInterval = 1.20
    /// After a sleep/wake or occlusion gap, the first frame's `dt` would otherwise be
    /// huge and the platter would jump to a random angle (spec §7.4).
    private let maxFrameDelta: TimeInterval = 0.1

    private(set) var angle: Double = 0
    private(set) var rpm: Double = 0

    var isPlaying = false
    var targetRPM: Double = TurntableSpeed.rpm33.rpm

    /// True while there's still visible motion — lets the caller stop its `TimelineView`
    /// only once coast-down has actually finished, not the instant playback pauses
    /// (spec §7.2: "paused: TimelineView stops the clock once the platter has fully
    /// stopped").
    var isActive: Bool { isPlaying || rpm > 0.5 }

    /// Advances by `dt` seconds (already clamped by the caller against the raw frame
    /// delta) and returns the new angle in degrees, 0..<360.
    @discardableResult
    func advance(dt rawDT: TimeInterval) -> Double {
        let dt = min(max(0, rawDT), maxFrameDelta)
        let target = isPlaying ? targetRPM : 0
        let tau = isPlaying ? spinUpTau : coastTau
        rpm += (target - rpm) * (1 - exp(-dt / tau))
        angle = (angle + rpm * 6 * dt).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        return angle
    }

    /// Snap to a known angle without touching `rpm` — used only for tests that need a
    /// deterministic starting point.
    func resetAngle(to value: Double = 0) {
        angle = value.truncatingRemainder(dividingBy: 360)
    }
}

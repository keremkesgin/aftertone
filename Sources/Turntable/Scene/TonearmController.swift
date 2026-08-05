import Foundation
import SwiftUI

/// Tonearm angle state machine (spec §7.3), extracted from the view so the lift-and-drop
/// sequence and the state table are testable without rendering.
final class TonearmController {
    /// Parked off the record.
    let restAngle: Double = -8
    let leadInAngle: Double = 4
    let runOutAngle: Double = 24
    /// Measured from the tonearm asset's own coordinate space; placeholder until Phase 5's
    /// real asset — must be re-measured against whatever `tonearm.png` actually ships.
    let pivot = UnitPoint(x: 0.82, y: 0.12)

    private(set) var currentAngle: Double
    /// True while a `liftAndDrop()` sequence owns `currentAngle` — `updateProgress` is a
    /// no-op during this window so the two don't fight over the same property
    /// (spec §14: "prefer explicit state machines... over chained implicit animations").
    private(set) var isTransitioning = false
    private var generation = 0

    init() {
        currentAngle = restAngle
    }

    /// Continuous per-frame tracking while playing/paused:
    /// `leadIn + progress * (runOut - leadIn)`, clamped (spec §7.3).
    func updateProgress(_ progress: Double) {
        guard !isTransitioning else { return }
        let clamped = min(1, max(0, progress))
        currentAngle = leadInAngle + clamped * (runOutAngle - leadInAngle)
    }

    /// Source stopped or not running: park immediately. Not the lift-and-drop sequence —
    /// that is reserved for a *track change* while the source is still alive (spec §7.3's
    /// state table lists this as a direct target, not a transition).
    func park() {
        generation += 1
        isTransitioning = false
        currentAngle = restAngle
    }

    /// "The single most charming detail in the app": lift to rest, hold, drop to lead-in
    /// — an explicit two-step sequence, not one animation (spec §7.3).
    ///
    /// `hold` is a parameter (not a hardcoded 250ms sleep) purely so tests can run this in
    /// microseconds instead of waiting on real time; production call sites use the
    /// default.
    func liftAndDrop(hold: Duration = .milliseconds(250)) async {
        generation += 1
        let myGeneration = generation

        isTransitioning = true
        currentAngle = restAngle

        try? await Task.sleep(for: hold)
        // A newer track change superseded this one mid-hold — let its own sequence own
        // the property from here; do not stomp it with a stale drop.
        guard myGeneration == generation else { return }

        currentAngle = leadInAngle
        guard myGeneration == generation else { return }
        isTransitioning = false
    }
}

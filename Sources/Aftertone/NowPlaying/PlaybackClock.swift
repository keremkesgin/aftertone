import Foundation

/// Interpolates playback position between 1Hz polls so animations can run at 30–60Hz
/// without jerking once per second (spec §5).
///
/// Two inputs: `sync(to:)` from the poll, `advance(to:)` from the display clock. Views
/// call `advance(to:)` at the top of a `TimelineView` body; calling it more than once for
/// the same instant is harmless because `dt` collapses to zero.
final class PlaybackClock {
    /// Beyond this the reported position cannot be a drift — the user scrubbed, or the
    /// track changed. Snap.
    private let snapThreshold: TimeInterval = 1.5
    /// Below this, correcting is visible jitter for no gain. Ignore.
    private let easeThreshold: TimeInterval = 0.05
    /// Fraction of remaining drift absorbed per frame. At 30fps this converges to under
    /// 2% of the original error in ~0.5s, which is what the Phase 2 criterion asks for.
    private let easeRate: Double = 0.25
    /// A frame delta larger than this means the display slept or the app was suspended.
    /// Without the clamp the first tick after wake is huge and the platter jumps to a
    /// random angle (spec §7.4).
    private let maxFrameDelta: TimeInterval = 0.1

    /// Interpolated position in seconds.
    private(set) var position: TimeInterval = 0
    /// Drift still to be absorbed, decayed at `easeRate` per frame.
    private(set) var residualDrift: TimeInterval = 0

    private var isPlaying = false
    private var trackID: String?
    private var lastTick: Date?

    /// Diagnostics for the Phase 2 spike; free to compute, so always on.
    private(set) var lastReportedPosition: TimeInterval = 0
    private(set) var lastSyncKind: SyncKind = .ignored

    enum SyncKind: String {
        case snapped, eased, ignored
    }

    // MARK: - Poll input

    /// Reconcile against ground truth from a poll.
    func sync(to reported: TimeInterval, trackID newTrackID: String?, isPlaying playing: Bool) {
        lastReportedPosition = reported
        isPlaying = playing

        // Any identity change resets hard — interpolating across a track boundary is
        // meaningless and would drag the tonearm through a bogus sweep (spec §5).
        if newTrackID != trackID {
            trackID = newTrackID
            snap(to: reported)
            return
        }

        let drift = reported - position
        if abs(drift) > snapThreshold {
            snap(to: reported)
        } else if abs(drift) > easeThreshold {
            residualDrift = drift
            lastSyncKind = .eased
        } else {
            lastSyncKind = .ignored
        }
    }

    /// Called when the source stops or quits: position is no longer meaningful.
    func reset() {
        isPlaying = false
        trackID = nil
        snap(to: 0)
    }

    private func snap(to value: TimeInterval) {
        position = max(0, value)
        residualDrift = 0
        lastSyncKind = .snapped
    }

    // MARK: - Frame input

    /// Advance to `now`, absorbing a slice of any outstanding drift.
    /// Returns the frame delta actually applied — useful for spin-up integration.
    @discardableResult
    func advance(to now: Date) -> TimeInterval {
        defer { lastTick = now }
        guard let lastTick else { return 0 }

        let raw = now.timeIntervalSince(lastTick)
        guard raw > 0 else { return 0 }
        let dt = min(raw, maxFrameDelta)

        if isPlaying {
            position += dt
        }

        if residualDrift != 0 {
            let correction = residualDrift * easeRate
            position += correction
            residualDrift -= correction
            // Stop chasing an error nobody can see; also keeps `residualDrift` from
            // decaying forever as a denormal.
            if abs(residualDrift) < 0.005 { residualDrift = 0 }
        }

        position = max(0, position)
        return dt
    }

    /// Discard the accumulated frame timestamp so the next `advance(to:)` contributes
    /// nothing. Call on wake from sleep and on becoming visible again (spec §7.4).
    func resetFrameTiming() {
        lastTick = nil
    }

    // MARK: - Derived

    /// Fraction through the track, clamped. Guards duration == 0, which Spotify reports
    /// for some ads and podcast episodes.
    func progress(duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
}

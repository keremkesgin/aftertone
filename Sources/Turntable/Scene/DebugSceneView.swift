import SwiftUI

/// Phase 1–2 development surface. Shows exactly what the provider and clock produce, so
/// the interpolation can be judged by eye before any artwork exists. Replaced in Phase 3.
struct DebugSceneView: View {
    @ObservedObject var monitor: NowPlayingMonitor

    var body: some View {
        // 30fps is the cap for the real scene (spec §7.4); use it here too so the
        // smoothness being judged is the smoothness that ships.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
            let _ = monitor.clock.advance(to: context.date)

            VStack(alignment: .leading, spacing: 14) {
                if let failure = monitor.failure {
                    StatusBanner(failure: failure, sourceName: monitor.provider.sourceName)
                }

                Text(monitor.snapshot.state.rawValue.uppercased())
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)

                if let track = monitor.snapshot.track {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.title3.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                        Text(track.album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }

                    let progress = monitor.clock.progress(duration: track.duration)
                    ProgressView(value: progress)
                    HStack {
                        Text(timecode(monitor.clock.position)).monospacedDigit()
                        Spacer()
                        Text(driftLabel)
                        Spacer()
                        Text(timecode(track.duration)).monospacedDigit()
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                    Text(track.artworkURL?.absoluteString ?? "no artwork url — placeholder")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                } else {
                    Text(idleMessage).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Stop the display clock entirely when nothing can move — a paused app must cost
    /// nothing (spec §7.4).
    private var isPaused: Bool {
        !monitor.snapshot.state.isPlaying && monitor.clock.residualDrift == 0
    }

    private var idleMessage: String {
        switch monitor.snapshot.state {
        case .notRunning: "\(monitor.provider.sourceName) isn't running."
        case .stopped: "Nothing playing."
        default: "…"
        }
    }

    private var driftLabel: String {
        String(format: "drift %+.3fs  ·  %@",
               monitor.clock.residualDrift, monitor.clock.lastSyncKind.rawValue)
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

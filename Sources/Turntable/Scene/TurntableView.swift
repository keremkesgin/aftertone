import SwiftUI

/// Phase 4 composite: deck background + spinning platter + tracking tonearm, driven by
/// `NowPlayingMonitor`/`PlaybackClock`/`ArtworkLoader`. Replaces `StaticSceneView` as the
/// default scene; `StaticSceneView` and `DebugSceneView` stay reachable behind
/// `--static-scene` / `--debug-scene` for comparison.
struct TurntableView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @ObservedObject var artwork: ArtworkLoader

    @State private var tonearm = TonearmController()
    /// Bumped on every tonearm-driving frame so the view re-reads `tonearm.currentAngle` —
    /// same reasoning as `PlatterView`'s `tick`: `TonearmController` is a plain class, not
    /// `ObservableObject`, since nothing about its state machine needs SwiftUI's diffing
    /// machinery except "please redraw."
    @State private var tick = 0
    @State private var lastTrackID: String?
    /// A genuine `@State` flag for "keep the render clock alive during a lift-and-drop" —
    /// deliberately *not* reading `tonearm.isTransitioning` for this. `tonearm` is a plain
    /// class; the async sequence mutates it from outside any SwiftUI-observed property, so
    /// nothing would tell the `TimelineView` to resume ticking at the exact moment a
    /// transition starts if the clock happened to already be paused. This flag is a real
    /// `@State` write, so it reliably re-triggers `body` and the `paused:` recomputation.
    @State private var isTransitioningUI = false

    /// Hardcoded default until Phase 6's Speed menu exists (spec §7.1: "Default 33⅓.
    /// Expose speed as a setting" — the *exposing* part is Phase 6's job).
    private let speed = TurntableSpeed.rpm33

    /// This clock's only jobs are advancing `PlaybackClock` and the tonearm's progress
    /// tracking — the platter has its own independent, self-pausing `TimelineView`
    /// (spec §7.4: "a paused app costs nothing"). Idle here means: not playing, no
    /// lift-and-drop in flight, and no residual clock drift left to ease in.
    private var isOuterActive: Bool {
        monitor.snapshot.state.isPlaying || isTransitioningUI || monitor.clock.residualDrift != 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isOuterActive)) { ctx in
            ZStack {
                SceneAsset.image("deck").resizable().aspectRatio(contentMode: .fill)

                PlatterView(artwork: artwork.state.map(\.image).map(Image.init(nsImage:)) ?? Image(systemName: "circle.fill"),
                            isPlaying: monitor.snapshot.state.isPlaying,
                            targetRPM: speed.rpm)
                    .frame(width: 320, height: 320)
                    .position(x: 260, y: 300)

                TonearmView(currentAngle: tonearm.currentAngle, pivot: tonearm.pivot)
                    .frame(width: 320, height: 320)
                    .position(x: 420, y: 220)
            }
            .onChange(of: ctx.date) { _, now in
                driveFrame(at: now)
            }
        }
        .frame(minWidth: 600, minHeight: 450)
        .overlay(alignment: .top) {
            if let failure = monitor.failure {
                StatusBanner(failure: failure, sourceName: monitor.provider.sourceName)
                    .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            trackLabel
        }
        .onChange(of: monitor.snapshot.track) { _, track in
            artwork.update(for: track)
            handleTrackChange(newID: track?.id)
        }
        .onAppear {
            artwork.update(for: monitor.snapshot.track)
            lastTrackID = monitor.snapshot.track?.id
        }
    }

    // MARK: - Per-frame drive

    private func driveFrame(at now: Date) {
        monitor.clock.advance(to: now)

        switch monitor.snapshot.state {
        case .playing, .paused:
            if let duration = monitor.snapshot.track?.duration {
                tonearm.updateProgress(monitor.clock.progress(duration: duration))
            }
        case .stopped, .notRunning:
            tonearm.park()
        }
        tick += 1
    }

    // MARK: - Track change → lift-and-drop (spec §7.3)

    private func handleTrackChange(newID: String?) {
        guard newID != lastTrackID else { return }
        lastTrackID = newID

        guard newID != nil, monitor.snapshot.state.isPlaying || monitor.snapshot.state == .paused else {
            // No track (source stopped) — park directly, no lift-and-drop theatrics for
            // a state that already has its own transition.
            tonearm.park()
            return
        }
        isTransitioningUI = true
        Task {
            await tonearm.liftAndDrop()
            isTransitioningUI = false
        }
    }

    // MARK: - Labels

    private var trackLabel: some View {
        VStack(spacing: 2) {
            if let track = monitor.snapshot.track {
                Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(idleMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 14)
    }

    private var idleMessage: String {
        switch monitor.snapshot.state {
        case .notRunning: "\(monitor.provider.sourceName) isn't running."
        default: "Nothing playing."
        }
    }
}

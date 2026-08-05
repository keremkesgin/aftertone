import SwiftUI

/// Spinning record + label. Rotation is driven by `PlatterPhysics` on a `TimelineView`
/// clock, never `repeatForever` — a `repeatForever` animation resets angle on interruption
/// and can't change speed smoothly (spec §7.2, §14).
struct PlatterView: View {
    let artwork: Image
    let isPlaying: Bool
    let targetRPM: Double

    @State private var physics = PlatterPhysics()
    @State private var lastTick: Date = .now
    /// Forces a view update each tick — `PlatterPhysics` isn't `ObservableObject` (there's
    /// no reason for SwiftUI's diffing machinery to watch it at 30fps; the TimelineView's
    /// own `ctx.date` already is the render clock), so this just nudges recomputation.
    @State private var tick = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { ctx in
            ZStack {
                SceneAsset.image("vinyl-grooves").resizable()
                artwork
                    .resizable()
                    .clipShape(Circle())
                    .scaleEffect(0.42) // label is ~42% of a 12" disc (spec §7.2)
            }
            .rotationEffect(.degrees(physics.angle))
            .onChange(of: ctx.date) { _, now in
                let dt = min(now.timeIntervalSince(lastTick), 0.1) // clamp after sleep
                lastTick = now
                physics.isPlaying = isPlaying
                physics.targetRPM = targetRPM
                physics.advance(dt: dt)
                tick += 1
            }
        }
        .drawingGroup()
    }

    private var isActive: Bool { isPlaying || physics.rpm > 0.5 }
}

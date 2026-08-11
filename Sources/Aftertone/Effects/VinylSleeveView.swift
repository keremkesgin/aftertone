import SwiftUI

/// A record + sleeve composition: album art round-cropped into the vinyl's center label,
/// and the same art square-cropped filling the sleeve card beside it. Vector-drawn, not a
/// photographed background — this app has no rights to reproduce an arbitrary reference
/// photo, and the original turntable-scene code this concept revives (see the README's
/// History section) was procedurally drawn for the same reason `PlaceholderLibrary`'s
/// bundled art is procedurally generated rather than sourced photos.
///
/// The record spins slowly while playing and freezes the instant playback pauses — same
/// "stop when the music stops" rule as the lyrics column and the (retired) ocean-wave
/// experiment. Unlike that wave effect, a plain rotation transform has no blur/filter
/// cost, so this is cheap to animate continuously. The disc sits on a square deck/plinth
/// with a corner knob — what makes it read as an actual turntable rather than a record
/// floating in space — and the sleeve leans at a slight angle beside it, its right edge
/// tucked partly behind the deck rather than sitting in a clean gap.
struct VinylSleeveView: View {
    let artworkImage: NSImage?
    let title: String
    let artist: String
    let isPlaying: Bool

    private let recordDiameter: CGFloat = 520
    private let labelDiameter: CGFloat = 180
    private let deckSize: CGFloat = 630
    private let sleeveSize: CGFloat = 650
    private let sleeveTiltDegrees: Double = -7
    /// Negative spacing pulls the sleeve and deck together until they overlap; drawn in
    /// this order the deck (added second) composites on top, so it's the deck's edge
    /// that visibly sits over the sleeve — "goes under the vinyl," not the reverse.
    private let overlap: CGFloat = -70
    private let grooveCount = 7
    // Real 33⅓ RPM reads as frantic at desktop-wallpaper scale, sitting behind other
    // content all day — this is a slow ambient spin, not a literal turntable speed.
    private static let revolutionsPerMinute = 6.0

    @State private var rotationDegrees: Double = 0
    @State private var lastTick: Date?

    var body: some View {
        HStack(spacing: overlap) {
            sleeve
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
                turntable
                    .onChange(of: context.date) { _, now in
                        advance(to: now)
                    }
            }
        }
        .onAppear { lastTick = nil }
        .onChange(of: isPlaying) { _, playing in
            // Dropping the recorded timestamp on pause→play means the next frame's delta
            // is measured from *now*, not from however long ago playback actually paused
            // — without this the disc would jump forward to make up for lost time.
            if playing { lastTick = nil }
        }
    }

    /// A nameplate affixed to the deck — like the manufacturer badge a real turntable has
    /// in its corner — rather than plain text floating below the scene. This is what
    /// makes the title/artist read as part of the machine instead of a caption.
    @ViewBuilder
    private var nameplate: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded).italic())
                .foregroundStyle(.black)
            Text(artist)
                .font(.system(size: 13, weight: .medium, design: .rounded).italic())
                .foregroundStyle(.black.opacity(0.7))
        }
        .lineLimit(1)
        // No background — reads as printed/engraved directly on the deck rather than a
        // tag stuck on top of it; black on the deck's light cream color is legible on its
        // own, no shadow needed the way white text against a bright photo would.
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func advance(to now: Date) {
        defer { lastTick = now }
        guard let lastTick, isPlaying else { return }
        let delta = now.timeIntervalSince(lastTick)
        // A delta this large means the display slept or the app was suspended, not that
        // 30 real seconds of playback elapsed between two 30fps ticks — skip it rather
        // than spin the disc through however many revolutions "should" have happened.
        guard delta > 0, delta < 1 else { return }
        rotationDegrees += delta * (Self.revolutionsPerMinute / 60.0) * 360.0
        if rotationDegrees >= 360 { rotationDegrees -= 360 }
    }

    /// A slight lean rather than flat-on — reads as a physical object leaning against
    /// something instead of a flat sticker, without needing real 3D perspective.
    @ViewBuilder
    private var sleeve: some View {
        artSquare
            .frame(width: sleeveSize, height: sleeveSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .rotationEffect(.degrees(sleeveTiltDegrees), anchor: .bottom)
            .shadow(color: .black.opacity(0.5), radius: 26, x: 8, y: 16)
    }

    /// The "vinyl machine": a square deck/plinth under the disc, plus a corner knob —
    /// what actually makes this read as a turntable rather than a record floating in
    /// space.
    @ViewBuilder
    private var turntable: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.93, green: 0.91, blue: 0.87))
                .frame(width: deckSize, height: deckSize)
                .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 16)

            record
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: deckSize, height: deckSize)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.75), Color(white: 0.45)],
                        startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .padding(24)

            // Opposite corner from the knob, overriding the ZStack's own bottomTrailing
            // default via an explicit frame + alignment on this one child.
            nameplate
                .padding(24)
                .frame(width: deckSize, height: deckSize, alignment: .bottomLeading)
        }
    }

    @ViewBuilder
    private var record: some View {
        ZStack {
            Circle()
                .fill(Color.black)

            // Grooves: faint concentric rings, evenly spaced from the label out to the
            // edge — enough to read as a record, not an attempt at photographic detail.
            ForEach(1...grooveCount, id: \.self) { index in
                let fraction = CGFloat(index) / CGFloat(grooveCount + 1)
                Circle()
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    .frame(width: recordDiameter * fraction, height: recordDiameter * fraction)
            }

            // A single soft highlight arc gives the black disc some dimension without
            // needing a photo or a lighting simulation.
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0.08), .clear, .clear, .clear],
                        center: .center),
                    lineWidth: recordDiameter * 0.5)
                .frame(width: recordDiameter * 0.75, height: recordDiameter * 0.75)
                .blendMode(.plusLighter)

            artCircle
                .frame(width: labelDiameter, height: labelDiameter)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.4), radius: 4)

            Circle()
                .fill(Color.black)
                .frame(width: 7, height: 7)
        }
        .frame(width: recordDiameter, height: recordDiameter)
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 14)
    }

    @ViewBuilder
    private var artSquare: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
        } else {
            Color(white: 0.85)
        }
    }

    @ViewBuilder
    private var artCircle: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
        } else {
            Color(white: 0.85)
        }
    }
}

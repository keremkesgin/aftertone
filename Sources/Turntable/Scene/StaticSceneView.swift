import SwiftUI

/// Phase 3 deliverable: square artwork, title, artist. No motion yet — that's Phase 4's
/// `PlatterView`/`TonearmView`. "Ugly is fine" (spec, Phase 3).
struct StaticSceneView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @ObservedObject var artwork: ArtworkLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure = monitor.failure {
                StatusBanner(failure: failure, sourceName: monitor.provider.sourceName)
            }

            ArtworkSquare(state: artwork.state)
                .frame(width: 220, height: 220)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 3) {
                if let track = monitor.snapshot.track {
                    Text(track.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(idleMessage).font(.body).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: monitor.snapshot.track) { _, track in artwork.update(for: track) }
        .onAppear { artwork.update(for: monitor.snapshot.track) }
    }

    private var idleMessage: String {
        switch monitor.snapshot.state {
        case .notRunning: "\(monitor.provider.sourceName) isn't running."
        default: "Nothing playing."
        }
    }
}

/// The artwork itself, cross-fading between images by identity (spec §6.1: 0.35s, "a hard
/// cut looks cheap").
private struct ArtworkSquare: View {
    let state: ArtworkState?

    var body: some View {
        ZStack {
            if let state {
                Image(nsImage: state.image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .id(state.id)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 8, y: 4)
        .animation(.easeInOut(duration: 0.35), value: state?.id)
    }
}

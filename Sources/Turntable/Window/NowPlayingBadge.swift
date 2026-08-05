import SwiftUI

/// Compact corner marker — artwork thumbnail + title/artist — used once the lyrics take
/// over as the desktop overlay's main content. `StaticSceneView` stays as its own thing
/// (still used by the `--static-scene` dev path); this is a smaller, purpose-built sibling
/// rather than a squeezed-down reuse of it.
struct NowPlayingBadge: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @ObservedObject var artwork: ArtworkLoader

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(state: artwork.state)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                if let track = monitor.snapshot.track {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                } else {
                    Text(idleMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
        .onAppear { artwork.update(for: monitor.snapshot.track) }
        .onChange(of: monitor.snapshot.track) { _, track in artwork.update(for: track) }
    }

    private var idleMessage: String {
        switch monitor.snapshot.state {
        case .notRunning: "\(monitor.provider.sourceName) isn't running"
        default: "Nothing playing"
        }
    }
}

private struct ArtworkThumbnail: View {
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
        .animation(.easeInOut(duration: 0.35), value: state?.id)
    }
}

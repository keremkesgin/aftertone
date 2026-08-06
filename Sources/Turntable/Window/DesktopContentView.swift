import SwiftUI

/// What actually renders at desktop level: a small centered badge (album art +
/// title/artist) and, when a matching `.lrc` exists, a bounded lyrics column beneath it —
/// not a full-screen takeover.
///
/// Normal SwiftUI view; hosting it via `NSHostingView` inside a hand-built `DesktopWindow`
/// works the same as any other host — `.onChange`/`.onAppear` don't care what kind of
/// `NSWindow` they end up inside.
struct DesktopContentView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @ObservedObject var artwork: ArtworkLoader
    @ObservedObject var lyrics: LyricsLibrary
    @ObservedObject var lyricsSyncSettings: LyricsSyncSettings
    @ObservedObject var overlaySettings: OverlaySettings

    private static let artworkSize: CGFloat = 140
    // Wide enough that a typical lyric line fits on one row rather than wrapping to two
    // or three and running out of the fixed height below.
    private static let lyricsWidth: CGFloat = 1300
    private static let lyricsHeight: CGFloat = 320
    private static let edgePadding: CGFloat = 56

    var body: some View {
        VStack(spacing: 24) {
            if let track = monitor.snapshot.track {
                badge(for: track)
            }

            if let document = lyrics.document {
                LyricsColumnView(monitor: monitor, syncSettings: lyricsSyncSettings, document: document)
                    .frame(width: Self.lyricsWidth, height: Self.lyricsHeight)
            }
        }
        .padding(Self.edgePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: overlaySettings.position.alignment)
        .onAppear {
            monitor.start()
            artwork.update(for: monitor.snapshot.track)
        }
        .onChange(of: monitor.snapshot.track) { _, track in
            artwork.update(for: track)
            lyrics.update(for: track)
        }
    }

    /// Placeholder artwork is deliberately hidden rather than shown: the user's own
    /// wallpaper is the backdrop here, so a bundled placeholder graphic would be a worse
    /// result than showing nothing at all.
    @ViewBuilder
    private func badge(for track: Track) -> some View {
        HStack(spacing: 14) {
            if let state = artwork.state, !state.isPlaceholder {
                Image(nsImage: state.image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
                    .id(state.id)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(track.artist)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
            .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
        }
        .animation(.easeInOut(duration: 0.35), value: artwork.state?.id)
    }
}

import SwiftUI

/// What actually renders at desktop level: a compact now-playing corner badge, and — the
/// main event — a large, Spotify-style animated lyrics column. Motion is paused pending
/// real assets, so this isn't the turntable scene; a desktop overlay is the wrong place
/// to run unverified animation unattended anyway.
///
/// Normal SwiftUI view; hosting it via `NSHostingView` inside a hand-built `DesktopWindow`
/// works the same as any other host — `.onChange`/`.onAppear` don't care what kind of
/// `NSWindow` they end up inside.
struct DesktopContentView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @ObservedObject var artwork: ArtworkLoader
    @ObservedObject var lyrics: LyricsLibrary

    var body: some View {
        ZStack(alignment: .topLeading) {
            NowPlayingBadge(monitor: monitor, artwork: artwork)
                .padding(28)

            if let document = lyrics.document {
                LyricsPanelView(monitor: monitor, document: document)
                    .padding(48)
                    .background(
                        RoundedRectangle(cornerRadius: 28)
                            .fill(.black.opacity(0.32))
                    )
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.start() }
        .onChange(of: monitor.snapshot.track) { _, track in
            lyrics.update(for: track)
        }
    }
}

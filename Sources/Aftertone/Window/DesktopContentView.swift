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
    @ObservedObject var lyricsVisibility: LyricsVisibilitySettings
    @ObservedObject var overlaySettings: OverlaySettings
    @ObservedObject var glowSettings: AlbumGlowSettings
    @ObservedObject var vinylModeSettings: VinylModeSettings
    @ObservedObject var gradientWallpaperSettings: GradientWallpaperSettings

    /// A corner placement needs to read as one small widget tucked into the corner, with
    /// the badge staying flush against the actual edge and lyrics extending sideways
    /// toward the middle of the screen — not stacked underneath the badge, which pushes a
    /// tall block down past the screen's vertical middle regardless of which corner was
    /// picked. `isTrailingCorner`/`cornerVerticalAlignment` decide which side of the
    /// badge the lyrics sit on and which edge the pair aligns to, so the lyrics always
    /// grow *away* from the corner rather than off toward a screen edge.
    private var isCorner: Bool { overlaySettings.position != .center }

    private var isTrailingCorner: Bool {
        overlaySettings.position == .topTrailing || overlaySettings.position == .bottomTrailing
    }

    private var cornerVerticalAlignment: VerticalAlignment {
        switch overlaySettings.position {
        case .bottomLeading, .bottomTrailing: .bottom
        default: .top
        }
    }

    private var cornerBadgeWidth: CGFloat { 140 }
    private var artworkSize: CGFloat { isCorner ? 88 : 140 }
    private var lyricsWidth: CGFloat { isCorner ? 380 : 1300 }
    private var lyricsHeight: CGFloat { isCorner ? 170 : 320 }
    private var lyricsFontSize: CGFloat { isCorner ? 19 : 46 }
    private var lyricsLineSpacing: CGFloat { isCorner ? 10 : 28 }
    private var titleFontSize: CGFloat { isCorner ? 14 : 17 }
    private var artistFontSize: CGFloat { isCorner ? 12 : 14 }
    private var blockSpacing: CGFloat { isCorner ? 20 : 24 }

    // Corner insets are deliberately asymmetric, unlike the center layout's uniform
    // padding: hugging the side edges reads as "in the corner," while the top edge still
    // needs real clearance so the badge doesn't sit under (or fight for space with) the
    // system menu bar — those are two different distances, not one `edgePadding` value.
    private var horizontalEdgePadding: CGFloat { isCorner ? 18 : 56 }
    private var topEdgePadding: CGFloat { isCorner ? 44 : 56 }
    private var bottomEdgePadding: CGFloat { isCorner ? 20 : 56 }

    var body: some View {
        ZStack {
            // Behind everything, in both layouts — the gradient is the backdrop the
            // badge or the vinyl composition sits on. Same placeholder rule as the
            // glow: a gradient derived from stale or bundled-placeholder colors has
            // nothing to do with what's playing, so it fades out rather than lying.
            if gradientWallpaperSettings.isEnabled, let state = artwork.state, !state.isPlaceholder {
                GradientWallpaperView(palette: artwork.palette)
                    .transition(.opacity.animation(.easeInOut(duration: 1.2)))
            }

            if vinylModeSettings.isEnabled {
                vinylLayout
            } else {
                badgeAndLyricsLayout
            }
        }
        .onAppear {
            monitor.start()
            artwork.update(for: monitor.snapshot.track)
        }
        .onChange(of: monitor.snapshot.track) { _, track in
            artwork.update(for: track)
            lyrics.update(for: track)
        }
    }

    /// Vinyl mode ignores `OverlaySettings.position` entirely (always centered, full
    /// size) and never shows lyrics — it's a distinct visual, not a variant of the badge
    /// layout the rest of this file builds.
    ///
    /// Gated on `track` alone, not on artwork being loaded: `ArtworkLoader` shows a
    /// placeholder for the instant between a skip and the new art finishing its fetch,
    /// and hiding the *entire* vinyl composition for that window (deck, sleeve, and text
    /// included) is what made the whole mode appear to vanish on every skip.
    /// `VinylSleeveView` already draws a neutral fallback for a `nil` image, so passing
    /// nil during that gap — instead of hiding the view — is what keeps it on screen.
    @ViewBuilder
    private var vinylLayout: some View {
        if let track = monitor.snapshot.track {
            let realImage = (artwork.state?.isPlaceholder == false) ? artwork.state?.image : nil
            VinylSleeveView(
                artworkImage: realImage, title: track.title, artist: track.artist,
                isPlaying: monitor.snapshot.state.isPlaying)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var badgeAndLyricsLayout: some View {
        ZStack {
            // Same rule the badge below uses: no glow for placeholder artwork, since a
            // stale or bundled-placeholder color has nothing to do with what's playing.
            if glowSettings.isEnabled, let state = artwork.state, !state.isPlaceholder {
                AlbumGlowView(palette: artwork.palette, sizeScale: glowSettings.sizeScale)
            }

            Group {
                if isCorner {
                    cornerLayout
                } else {
                    centerLayout
                }
            }
            .padding(.horizontal, horizontalEdgePadding)
            .padding(.top, topEdgePadding)
            .padding(.bottom, bottomEdgePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: overlaySettings.position.alignment)
        }
    }

    @ViewBuilder
    private var centerLayout: some View {
        VStack(spacing: blockSpacing) {
            if let track = monitor.snapshot.track {
                sideBySideBadge(for: track)
            }
            if lyricsVisibility.isEnabled, let document = lyrics.document {
                LyricsColumnView(
                    monitor: monitor, syncSettings: lyricsSyncSettings, document: document,
                    fontSize: lyricsFontSize, lineSpacing: lyricsLineSpacing)
                    .frame(width: lyricsWidth, height: lyricsHeight)
            }
        }
    }

    @ViewBuilder
    private var cornerLayout: some View {
        let badgeView = Group {
            if let track = monitor.snapshot.track { stackedBadge(for: track) }
        }
        let lyricsView = Group {
            if lyricsVisibility.isEnabled, let document = lyrics.document {
                LyricsColumnView(
                    monitor: monitor, syncSettings: lyricsSyncSettings, document: document,
                    fontSize: lyricsFontSize, lineSpacing: lyricsLineSpacing)
                    .frame(width: lyricsWidth, height: lyricsHeight)
            }
        }
        HStack(alignment: cornerVerticalAlignment, spacing: blockSpacing) {
            if isTrailingCorner {
                lyricsView
                badgeView
            } else {
                badgeView
                lyricsView
            }
        }
    }

    /// Corner layout: art on top, title and artist centered beneath it, pinned to
    /// `cornerBadgeWidth` — a narrow column sitting beside the lyrics box, not above it.
    @ViewBuilder
    private func stackedBadge(for track: Track) -> some View {
        VStack(spacing: 10) {
            if let state = artwork.state, !state.isPlaceholder {
                Image(nsImage: state.image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)
                    .id(state.id)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }

            VStack(spacing: 3) {
                Text(track.title)
                    .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(track.artist)
                    .font(.system(size: artistFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
        }
        .frame(width: cornerBadgeWidth)
        .animation(.easeInOut(duration: 0.35), value: artwork.state?.id)
    }

    /// Centered layout: art and title/artist side by side, both left-aligned to each
    /// other — reads fine in the middle of the screen where nothing else needs to share
    /// its alignment axis.
    @ViewBuilder
    private func sideBySideBadge(for track: Track) -> some View {
        HStack(spacing: 14) {
            if let state = artwork.state, !state.isPlaceholder {
                Image(nsImage: state.image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
                    .id(state.id)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(track.artist)
                    .font(.system(size: artistFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
            .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
        }
        .animation(.easeInOut(duration: 0.35), value: artwork.state?.id)
    }
}

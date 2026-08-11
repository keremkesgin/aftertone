import SwiftUI

/// Centered lyrics column below the artwork/title block. Position is driven from
/// `PlaybackClock`, never the raw 1Hz poll — that's what keeps the active line tracking
/// smoothly between polls instead of stepping once per second.
struct LyricsColumnView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @ObservedObject var syncSettings: LyricsSyncSettings
    let document: LyricsDocument
    /// Lets a small corner placement use a proportionally smaller typeface than the
    /// centered layout — a corner box sized for reading distance doesn't fit the same
    /// 46pt type a full-width centered column does.
    var fontSize: CGFloat = 46
    var lineSpacing: CGFloat = 28

    @State private var position: TimeInterval = 0
    @State private var wordLayouts: [Int: WordFillLayout?] = [:]
    @State private var cachedActiveIndex: Int?

    private var trackDuration: TimeInterval { monitor.snapshot.track?.duration ?? 0 }
    private var activeIndex: Int? { document.activeIndex(at: position) }
    private var lineFont: Font { .system(size: fontSize, weight: .bold, design: .rounded) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !monitor.snapshot.state.isPlaying)) { ctx in
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .center, spacing: lineSpacing) {
                            ForEach(document.lines.indices, id: \.self) { index in
                                line(at: index).id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Half a viewport of blank space top and bottom so even the
                        // first/last line has room to actually reach the center —
                        // `ScrollView` clamps `scrollTo` to content bounds, and without
                        // this the first line could never scroll past its own top edge.
                        .padding(.vertical, geometry.size.height / 2)
                    }
                    // This is a fixed-position display, not something the user drags —
                    // `scrollTo` still works with scrolling disabled; only manual
                    // dragging is turned off.
                    .scrollDisabled(true)
                    .onChange(of: ctx.date) { _, _ in
                        position = monitor.clock.position + syncSettings.offset
                        if activeIndex != cachedActiveIndex {
                            cachedActiveIndex = activeIndex
                            primeWordLayout(for: activeIndex)
                            scrollToActive(proxy)
                        }
                    }
                    .onAppear {
                        position = monitor.clock.position + syncSettings.offset
                        cachedActiveIndex = activeIndex
                        primeWordLayout(for: activeIndex)
                        scrollToActive(proxy, animated: false)
                    }
                }
            }
        }
        // A hard `.clipped()` alone chops the top/bottom lines off mid-character as they
        // scroll past the edge, which reads as broken rather than intentional. Fading
        // them out first is what makes the same clipping look like a deliberate edge
        // rather than a bug.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        )
        .clipped()
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let activeIndex else { return }
        if animated {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                proxy.scrollTo(activeIndex, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    // MARK: - Per-line rendering

    // Bold, center-aligned, word-wrapped — this is a desktop overlay competing with an
    // arbitrary wallpaper photo behind it, not a panel in a normal app window, so the
    // styling favors legibility over subtlety: a large weight throughout (Spotify's own
    // full-screen lyrics view does the same — the active line isn't a different
    // *weight*, it's full-opacity white against everything else dimmed) and a shadow so
    // white text doesn't vanish against a bright photo. `fontSize` scales this down for
    // a small corner placement.

    @ViewBuilder
    private func line(at index: Int) -> some View {
        let lyricLine = document.lines[index]
        let distance = Double(abs(index - (activeIndex ?? index)))
        let isActive = index == activeIndex

        Group {
            if isActive, let layout = wordLayouts[index] ?? nil {
                wordFillText(lyricLine, layout: layout, index: index)
            } else {
                Text(lyricLine.text)
                    .foregroundStyle(.white)
            }
        }
        .font(lineFont)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true) // wrap within the available width, never truncate
        .frame(maxWidth: .infinity, alignment: .center)
        .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 2)
        // Focus falloff — every line dims and blurs with distance from the active one.
        .opacity(max(0.15, 1.0 - 0.55 * distance))
        .blur(radius: min(4.0, distance * 1.4))
        // Active-line emphasis.
        .scaleEffect(isActive ? 1.06 : 1.0, anchor: .center)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: activeIndex)
    }

    /// Word-level fill (enhanced LRC only) — bright text revealed over dim text through a
    /// gradient mask whose edge tracks word progress (spec §8.4).
    @ViewBuilder
    private func wordFillText(_ lyricLine: LyricLine, layout: WordFillLayout, index: Int) -> some View {
        let end = document.end(of: index, trackDuration: trackDuration)
        let progress = WordFill.fillProgress(layout, position: position, lineEnd: end)

        Text(lyricLine.text)
            .foregroundStyle(.white.opacity(0.45))
            .overlay(alignment: .leading) {
                Text(lyricLine.text)
                    .foregroundStyle(.white)
                    .mask(alignment: .leading) {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: progress),
                                .init(color: .clear, location: min(1.0, progress + 0.02)),
                            ],
                            startPoint: .leading, endPoint: .trailing)
                    }
            }
    }

    /// Recomputes the (cheap) character-offset table only when the active line changes —
    /// never per frame (spec §8.4).
    private func primeWordLayout(for index: Int?) {
        guard let index, wordLayouts[index] == nil else { return }
        wordLayouts[index] = .some(WordFill.layout(for: document.lines[index]))
    }
}

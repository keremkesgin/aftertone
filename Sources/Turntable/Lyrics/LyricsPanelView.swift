import SwiftUI

/// Separate toggleable panel beside the deck — never text layered over the record
/// (spec §8.5). Position is driven from `PlaybackClock`, never the raw poll (spec §8.4).
struct LyricsPanelView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    let document: LyricsDocument

    @State private var position: TimeInterval = 0
    @State private var lineFrames: [Int: CGRect] = [:]
    @State private var wordLayouts: [Int: WordFillLayout?] = [:]
    @State private var cachedActiveIndex: Int?

    private var trackDuration: TimeInterval { monitor.snapshot.track?.duration ?? 0 }
    private var activeIndex: Int? { document.activeIndex(at: position) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !monitor.snapshot.state.isPlaying)) { ctx in
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(document.lines.indices, id: \.self) { index in
                        line(at: index, viewportHeight: geometry.size.height)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: scrollOffset(viewportHeight: geometry.size.height))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: activeIndex)
                .coordinateSpace(name: Self.coordinateSpace)
                .onPreferenceChange(LineFramePreferenceKey.self) { lineFrames = $0 }
                .onChange(of: ctx.date) { _, _ in
                    position = monitor.clock.position
                    if activeIndex != cachedActiveIndex {
                        cachedActiveIndex = activeIndex
                        primeWordLayout(for: activeIndex)
                    }
                }
            }
        }
        .clipped()
        .onAppear {
            position = monitor.clock.position
            cachedActiveIndex = activeIndex
            primeWordLayout(for: activeIndex)
        }
    }

    private static let coordinateSpace = "LyricsPanelView.lines"

    // MARK: - Per-line rendering

    /// Big, bold, left-aligned, word-wrapped — this is a desktop overlay competing with
    /// an arbitrary wallpaper photo behind it, not a panel in a normal app window, so the
    /// styling favors legibility from across a room over subtlety: a large weight
    /// throughout (Spotify's own full-screen lyrics view does the same — the active line
    /// isn't a different *weight*, it's full-opacity white against everything else dimmed)
    /// and a shadow so white text doesn't vanish against a bright photo.
    private static let lineFont = Font.system(size: 40, weight: .bold, design: .rounded)

    @ViewBuilder
    private func line(at index: Int, viewportHeight: CGFloat) -> some View {
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
        .font(Self.lineFont)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true) // wrap within the available width, never truncate
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 2)
        // Focus falloff — every line (spec §8.4).
        .opacity(max(0.15, 1.0 - 0.55 * distance))
        .blur(radius: min(4.0, distance * 1.4))
        // Active-line emphasis (spec §8.4).
        .scaleEffect(isActive ? 1.06 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: activeIndex)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LineFramePreferenceKey.self,
                    value: [index: proxy.frame(in: .named(Self.coordinateSpace))])
            }
        )
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

    // MARK: - Scrolling

    /// An explicit animated `offset`, not `ScrollViewReader.scrollTo` — full control over
    /// easing, and it won't fight rapid line changes during fast passages (spec §8.4).
    private func scrollOffset(viewportHeight: CGFloat) -> CGFloat {
        guard let activeIndex, let frame = lineFrames[activeIndex] else { return 0 }
        return viewportHeight / 2 - frame.midY
    }
}

private struct LineFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

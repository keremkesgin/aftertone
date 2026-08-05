import SwiftUI

/// Phase 1–4 shell: a plain window over `TurntableView` (the composited platter +
/// tonearm scene, spec §7). Phase 6 replaces this scene with an `NSStatusItem` plus a
/// `FloatingPanel` (spec §9).
///
/// `--static-scene` and `--debug-scene` swap in the earlier phases' views — kept, not
/// deleted, since each still verifies something the others don't (Phase 3's plain
/// artwork/title/artist layout; Phase 1–2's raw provider/clock readout).
///
/// The lyrics panel (spec §8) is wired at this top level, beside whichever scene is
/// active, rather than inside each scene view — one hook instead of three, and it means
/// swapping scenes never risks forgetting to wire it into a new one.
struct TurntableApp: App {
    @StateObject private var monitor = NowPlayingMonitor()
    @StateObject private var artwork = ArtworkLoader(library: PlaceholderLibrary())
    @StateObject private var lyrics = LyricsLibrary(store: LyricsStore())

    private enum SceneChoice { case turntable, staticScene, debug }

    private var sceneChoice: SceneChoice {
        let args = CommandLine.arguments
        if args.contains("--debug-scene") { return .debug }
        if args.contains("--static-scene") { return .staticScene }
        return .turntable
    }

    var body: some Scene {
        Window("Turntable", id: "turntable") {
            HStack(spacing: 0) {
                Group {
                    switch sceneChoice {
                    case .turntable: TurntableView(monitor: monitor, artwork: artwork)
                    case .staticScene: StaticSceneView(monitor: monitor, artwork: artwork)
                    case .debug: DebugSceneView(monitor: monitor)
                    }
                }
                .frame(minWidth: 420, minHeight: 420)

                // Separate panel beside the deck, never text over the record (spec §8.5).
                // Shown exactly when there's something to show — no `.lrc` match is not
                // an error, it's silence (spec §12).
                if let document = lyrics.document {
                    Divider()
                    LyricsPanelView(monitor: monitor, document: document)
                        .frame(minWidth: 280, idealWidth: 340)
                        .padding(16)
                }
            }
            .onAppear { monitor.start() }
            .onChange(of: monitor.snapshot.track) { _, track in
                lyrics.update(for: track)
            }
        }
        .windowResizability(.contentMinSize)
    }
}

import AppKit

// Top-level entry point rather than `@main` so the spike harness can run without any UI.
// `TurntableApp` is invoked explicitly below.

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.run() }
} else if arguments.contains("--bench") {
    MainActor.assumeIsolated { PollBench.run() }
} else if arguments.contains("--artwork-bench") {
    MainActor.assumeIsolated { ArtworkBench.run() }
} else if arguments.contains("--lyrics-bench") {
    MainActor.assumeIsolated { LyricsBench.run() }
} else if arguments.contains("--spike") || arguments.contains("--spike-clock") {
    // Headless: no NSApplication activation, no window. Phases 1–2 verification.
    let seconds = CommandLine.arguments
        .drop(while: { $0 != "--seconds" })
        .dropFirst()
        .first
        .flatMap(Double.init) ?? 20
    // Top-level code is nonisolated; the spike (and NSAppleScript inside it) is main-actor
    // bound, and this *is* the main thread, so assert that rather than hopping.
    MainActor.assumeIsolated {
        Spike.run(clockMode: arguments.contains("--spike-clock"), seconds: seconds)
    }
} else if arguments.contains("--window-mode") {
    // Dev-only fallback: the old SwiftUI `Window`-scene presentation (supports
    // --debug-scene / --static-scene). Useful for inspecting a scene in a normal,
    // draggable, focusable window instead of the click-through desktop-level one.
    TurntableApp.main()
} else {
    // The real app: a desktop-level window plus a status item, no SwiftUI Scene at all
    // (see AppDelegate's doc comment for why).
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

import AppKit

// Top-level entry point rather than `@main` so the CLI harnesses can run without any UI.

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.run() }
} else if arguments.contains("--bench") {
    MainActor.assumeIsolated { PollBench.run() }
} else if arguments.contains("--artwork-bench") {
    MainActor.assumeIsolated { ArtworkBench.run() }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

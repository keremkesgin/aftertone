import AppKit
import Combine
import Foundation

/// Headless verification harness for the Phase 1 and Phase 2 acceptance criteria.
///
/// Run it through the *bundled* executable, not a loose binary:
///
///     make spike            # Phase 1 — 1Hz provider output
///     make spike-clock      # Phase 2 — 60Hz interpolation + drift diagnostics
///
/// Running `build/Turntable.app/Contents/MacOS/Turntable` keeps the app's own code
/// signature and bundle identity, so the Automation TCC prompt is attributed to
/// Turntable rather than to Terminal. A loose `swift run` binary would be attributed to
/// the terminal and would not exercise the real permission path.
@MainActor
enum Spike {
    static func run(clockMode: Bool, seconds: TimeInterval) {
        let provider = SpotifyProvider()
        let monitor = NowPlayingMonitor(provider: provider)

        print("— Turntable spike (\(clockMode ? "clock, 60Hz" : "provider, 1Hz")), \(Int(seconds))s —")
        print("bundle: \(Bundle.main.bundleIdentifier ?? "nil")  source: \(provider.sourceName)")
        print("")

        var cancellables: [Any] = []
        cancellables.append(monitor.objectWillChange.sink { _ in
            // Report on the next turn, once @Published values have actually landed.
            DispatchQueue.main.async { reportPoll(monitor) }
        })

        monitor.start()

        if clockMode { startFrameTicker(monitor) }
        startMainThreadWatchdog()

        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                monitor.stop()
                reportWatchdog()
                print("\n— done —")
                exit(0)
            }
        }

        withExtendedLifetime(cancellables) {
            RunLoop.main.run()
        }
    }

    // MARK: - Phase 1 reporting

    private static var lastReportedLine = ""

    private static func reportPoll(_ monitor: NowPlayingMonitor) {
        let line: String
        if let failure = monitor.failure {
            switch failure {
            case .automationDenied:
                // This is the banner path. In the app this is a persistent banner with a
                // button; here we print the same information once per transition.
                line = "DENIED   automation refused (-1743) → banner + deep-link to "
                     + "System Settings ▸ Privacy & Security ▸ Automation"
            case let .providerError(code, message):
                line = "ERROR    \(code): \(message)"
            }
        } else {
            let snapshot = monitor.snapshot
            switch snapshot.state {
            case .notRunning:
                line = "idle     Spotify isn't running"
            case .stopped:
                line = "idle     stopped"
            case .playing, .paused:
                guard let track = snapshot.track else { return }
                let position = String(format: "%6.2f", snapshot.position)
                let duration = String(format: "%6.2f", track.duration)
                line = "\(snapshot.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
                     + "\(position)/\(duration)s  "
                     + "\(track.title) — \(track.artist)  [\(track.album)]  "
                     + "art:\(track.artworkURL == nil ? "none" : "yes")  id:\(track.id)"
            }
        }

        // Suppress identical idle/denied spam; a changing position always differs.
        guard line != lastReportedLine else { return }
        lastReportedLine = line
        print("\(stamp())  \(line)")
    }

    // MARK: - Phase 2 reporting

    private static func startFrameTicker(_ monitor: NowPlayingMonitor) {
        var frame = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let dt = monitor.clock.advance(to: Date())
                frame += 1
                // 20Hz of output: enough rows to see that the interpolation is smooth and
                // that a scrub re-converges, without drowning the terminal.
                guard frame % 3 == 0 else { return }
                let clock = monitor.clock
                print(String(
                    format: "%@  f%05d dt=%.4f  local=%8.3f  reported=%8.3f  drift=%+7.3f  %@",
                    stamp(), frame, dt, clock.position, clock.lastReportedPosition,
                    clock.residualDrift, clock.lastSyncKind.rawValue))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Main-thread responsiveness

    /// Ticks at 240Hz (4.2ms) and records how late each tick lands. If polling still
    /// blocked the main thread the way spec §4.4 has it, a ~90ms poll would show up here
    /// as a ~90ms gap once per second. This is the live version of the `make bench`
    /// off-main-thread finding — proof against the real client, not a synthetic probe.
    private static var watchdogLast: Date?
    private static var watchdogWorst: TimeInterval = 0
    private static var watchdogSamples = 0

    private static func startMainThreadWatchdog() {
        watchdogLast = Date()
        let timer = Timer(timeInterval: 1.0 / 240.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                if let last = watchdogLast {
                    watchdogWorst = max(watchdogWorst, now.timeIntervalSince(last))
                    watchdogSamples += 1
                }
                watchdogLast = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func reportWatchdog() {
        print(String(
            format: "main-thread watchdog: %d ticks, worst gap %.2fms"
                + " (a blocking 80-90ms poll would show here as ~90ms)",
            watchdogSamples, watchdogWorst * 1000))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

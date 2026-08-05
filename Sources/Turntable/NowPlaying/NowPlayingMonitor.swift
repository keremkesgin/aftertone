import AppKit
import Combine
import Foundation

/// Owns the provider and the poll timer. Everything in the app reads state from here;
/// nothing else talks to a provider.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    /// Poll intervals by state (spec §4.5).
    enum Cadence {
        static let playing: TimeInterval = 1.0
        static let paused: TimeInterval = 3.0
        static let idle: TimeInterval = 5.0
        /// Automation was denied. Keep a slow heartbeat so granting it in System Settings
        /// recovers on its own, without hammering a call that can only fail (spec §4.6).
        static let denied: TimeInterval = 10.0
    }

    @Published private(set) var snapshot: NowPlaying = .notRunning
    /// Non-nil surfaces in the menu bar label. Cleared automatically on the first good poll.
    @Published private(set) var failure: NowPlayingFailure?

    let provider: NowPlayingProvider

    /// Set during system sleep and fast user switching.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended {
                timer?.invalidate()
                timer = nil
            } else {
                poll()
                reschedule()
            }
        }
    }

    /// Round-trip latency of the last poll, and the worst seen. Diagnostic only — since
    /// `SpotifyProvider.poll()` runs off the main thread (see its doc comment), this
    /// number no longer costs the animation anything, however large it is.
    private(set) var lastPollDuration: TimeInterval = 0
    private(set) var maxPollDuration: TimeInterval = 0
    private(set) var pollCount = 0

    private var timer: Timer?
    private var currentInterval: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    /// Guards against a slow poll and the next timer tick overlapping. At measured
    /// latencies (~90ms) against a 1s-minimum cadence this is cheap insurance, not a
    /// response to anything actually observed.
    private var isPolling = false

    init(provider: NowPlayingProvider = SpotifyProvider()) {
        self.provider = provider
        registerForSystemNotifications()
    }

    deinit {
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    // MARK: - Lifecycle

    func start() {
        poll()
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentInterval = nil
    }

    // MARK: - Polling

    func poll() {
        guard !isPolling else { return }
        isPolling = true
        let started = CFAbsoluteTimeGetCurrent()

        // This closure inherits @MainActor isolation from `poll()`'s enclosing context
        // (Task {} created inside a MainActor method runs its body on that actor), so the
        // only genuine suspension below is inside `provider.poll()` itself — where
        // SpotifyProvider hops off to its own serial queue. `finishPoll` afterwards is a
        // plain, non-suspending call back on the actor we never left.
        Task { [weak self, provider] in
            let outcome: Result<NowPlaying, Error>
            do {
                outcome = .success(try await provider.poll())
            } catch {
                outcome = .failure(error)
            }
            self?.finishPoll(outcome, started: started)
        }
    }

    private func finishPoll(_ outcome: Result<NowPlaying, Error>, started: CFAbsoluteTime) {
        isPolling = false
        lastPollDuration = CFAbsoluteTimeGetCurrent() - started
        maxPollDuration = max(maxPollDuration, lastPollDuration)
        pollCount += 1

        switch outcome {
        case .success(let result):
            failure = nil
            snapshot = result
        case .failure(let error as NowPlayingFailure):
            failure = error
            // Look idle rather than frozen on a stale track.
            snapshot = .notRunning
        case .failure(let error):
            failure = .providerError(code: 0, message: error.localizedDescription)
            snapshot = .notRunning
        }
        reschedule()
    }

    // MARK: - Scheduling

    private var desiredInterval: TimeInterval {
        if failure == .automationDenied { return Cadence.denied }
        switch snapshot.state {
        case .playing: return Cadence.playing
        case .paused: return Cadence.paused
        case .stopped, .notRunning: return Cadence.idle
        }
    }

    private func reschedule() {
        guard !isSuspended else { return }
        let interval = desiredInterval
        guard interval != currentInterval || timer == nil else { return }

        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Let the system coalesce our wakeup with others it already has scheduled.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        currentInterval = interval
    }

    // MARK: - System notifications

    private func registerForSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: NSNotification.Name, _ handler: @escaping @MainActor () -> Void) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            observers.append(observer)
        }

        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.isSuspended = true }
        observe(NSWorkspace.didWakeNotification) { [weak self] in self?.isSuspended = false }
        // Fast user switching: our session is not on screen, so stop everything (spec §7.4).
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.isSuspended = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.isSuspended = false }
    }

    // MARK: - Remediation

    /// Deep-link to the Automation pane so the banner's button lands somewhere useful.
    static func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}

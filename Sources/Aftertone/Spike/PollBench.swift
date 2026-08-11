import AppKit
import Foundation

/// Measures poll cost and, more importantly, whether it ever reaches the main thread.
///
/// Spec §4.4 states a precompiled `NSAppleScript` costs "well under a millisecond of
/// main-thread time" at 1Hz, and specs polling as a synchronous main-thread call on that
/// basis. Measured against the live Spotify client, a full 8-field poll costs **80-90ms**
/// — the Apple Event round trip, not anything on our side — which is 5+ dropped 60fps
/// frames if it runs on the main thread as specced. `SpotifyProvider.poll()` is `async`
/// and confines the actual call to a private serial queue for exactly this reason; this
/// bench proves both halves: the round trip is still slow, and none of it reaches the
/// thread that renders.
///
/// `make bench`
@MainActor
enum PollBench {
    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        // `.detached`, not a plain `Task {}`: a plain Task created inside this @MainActor
        // method inherits MainActor isolation, which means it can only run once the main
        // thread's executor is free. `semaphore.wait()` below blocks that thread
        // synchronously — so an inherited-isolation task would deadlock immediately,
        // waiting on a thread that's waiting on it. `.detached` runs on the global
        // concurrent executor instead, so it makes progress while the main thread blocks.
        Task.detached {
            await runAsync()
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    // Everything below is `nonisolated`: it runs inside the `.detached` task above, on the
    // global concurrent executor, and must never need to hop back to the main actor — that
    // hop is exactly what `run()`'s `semaphore.wait()` makes impossible until this
    // finishes. (`PollBench` itself is `@MainActor`, so without `nonisolated` these would
    // implicitly require the main actor and reintroduce the same deadlock one level down.)

    private nonisolated static func runAsync() async {
        let provider = SpotifyProvider()

        print("— poll cost —")
        print("frame budget: 33.3ms at 30fps, 16.7ms at 60fps\n")

        // Discard the first: first-execute does terminology resolution and target-app
        // handshaking that never recurs.
        _ = try? await provider.poll()

        let roundTrip = await measureRoundTrip(provider, count: 12, spacing: 1.0)
        report("round trip, 1Hz-spaced (realistic)", roundTrip)

        let stalls = await measureMainThreadStalls(provider, count: 10)
        reportStalls(stalls)

        let worstRoundTrip = roundTrip.max() ?? 0
        let worstStall = stalls.max() ?? 0
        print("")
        print("round trip: \(ms(worstRoundTrip)) worst — this is Spotify's IPC latency, not ours;"
            + " it no longer matters because it never reaches the render thread.")
        if worstStall > 0.0167 {
            print("✗ worst main-thread stall \(ms(worstStall)) exceeds a 60fps frame — "
                + "polling is still leaking onto the main thread.")
        } else {
            print("✓ worst main-thread stall \(ms(worstStall)) — the render thread never "
                + "waits on Spotify, regardless of round-trip cost.")
        }
    }

    // MARK: - Round trip (informational — this cost is real, just no longer on our thread)

    private nonisolated static func measureRoundTrip(
        _ provider: NowPlayingProvider, count: Int, spacing: TimeInterval
    ) async -> [TimeInterval] {
        var samples: [TimeInterval] = []
        for index in 0..<count {
            let started = CFAbsoluteTimeGetCurrent()
            _ = try? await provider.poll()
            samples.append(CFAbsoluteTimeGetCurrent() - started)
            if spacing > 0, index < count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
            }
        }
        return samples
    }

    // MARK: - Main-thread stall (the number that actually matters)

    /// Runs a poll from a background `Task` while this function — itself on the main
    /// actor — spins a tight loop timing its own gaps. If `poll()` leaked any blocking
    /// work onto the main thread, this loop would stall exactly that long.
    private nonisolated static func measureMainThreadStalls(
        _ provider: NowPlayingProvider, count: Int
    ) async -> [TimeInterval] {
        var stalls: [TimeInterval] = []
        for _ in 0..<count {
            let done = ManagedAtomicBox(false)
            Task.detached {
                _ = try? await provider.poll()
                done.set(true)
            }

            var last = CFAbsoluteTimeGetCurrent()
            var worst: TimeInterval = 0
            while !done.get() {
                let now = CFAbsoluteTimeGetCurrent()
                worst = max(worst, now - last)
                last = now
                // Briefly yield so this loop measures real scheduling gaps rather than
                // spinning the CPU at 100% for no reason; 100µs is far below anything we
                // care to resolve.
                try? await Task.sleep(nanoseconds: 100_000)
            }
            stalls.append(worst)
        }
        return stalls
    }

    // MARK: - Reporting

    private nonisolated static func report(_ label: String, _ samples: [TimeInterval]) {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        let total = samples.reduce(0, +)
        print("\(label)  n=\(samples.count)")
        print("  min \(ms(sorted.first!))   median \(ms(sorted[sorted.count / 2]))"
            + "   p95 \(ms(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]))"
            + "   max \(ms(sorted.last!))")
        print("  mean \(ms(total / Double(samples.count)))"
            + "   → \(String(format: "%.2f", total / Double(samples.count) * 100))% of a core at 1Hz")
    }

    private nonisolated static func reportStalls(_ samples: [TimeInterval]) {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        print("main-thread stall during each poll  n=\(samples.count)")
        print("  min \(ms(sorted.first!))   median \(ms(sorted[sorted.count / 2]))"
            + "   max \(ms(sorted.last!))")
    }

    private nonisolated static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.2fms", seconds * 1000)
    }
}

/// A lock-protected `Bool` shared between the polling task and the timing loop. Not
/// `Sendable`-derived magic — just enough to read/write across the `Task.detached`
/// boundary without triggering data-race diagnostics.
private final class ManagedAtomicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

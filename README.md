# Turntable

A macOS background app that mirrors whatever is playing in the **Spotify desktop client**
by setting your actual desktop wallpaper to the current track's album artwork. No windows,
no overlay — just a menu bar item (now-playing label + Quit).

## Stack

| | |
|---|---|
| Language | Swift (5.9 language mode, built with the 6.3 toolchain) |
| UI | AppKit — a single `NSStatusItem`, nothing else |
| Minimum OS | macOS 14.0 |
| Build system | SwiftPM + `Makefile` |
| Dependencies | none |

**Why SwiftPM and not an `.xcodeproj`:** this machine has Command Line Tools but no
Xcode, so `xcodebuild` is unavailable. The CLT toolchain compiles AppKit against the
macOS SDK without trouble, so the package builds a bare executable and the `Makefile`
assembles the `.app` bundle around it — `Info.plist`, `Resources/`, code signature. A
SwiftPM package also opens directly in Xcode if you install it later, so nothing is lost.

## How it works

`AppDelegate` owns a `NowPlayingMonitor` (polls Spotify via AppleScript on a cadence that
backs off when paused/idle), an `ArtworkLoader` (memory cache → disk cache → network →
bundled placeholder, so there's always an image), and a `WallpaperSetter`. Two Combine
subscriptions wire them together: track changes flow into the artwork loader, and
non-placeholder artwork states flow into `WallpaperSetter.apply(_:)`, which writes the
image to a stable file (`~/Library/Application Support/<bundle-id>/wallpaper.jpg`,
overwritten in place — `NSWorkspace.setDesktopImageURL` needs a URL that stays valid after
the call returns) and calls it for every `NSScreen`.

Placeholder artwork is deliberately filtered out of that second subscription: when nothing
is playing, or when Spotify has no artwork for the current item, the wallpaper is left
exactly as it was rather than being overwritten with a placeholder graphic. The very first
launch behaves the same way — your existing wallpaper stays put until the first real track
loads.

`StatusItemController` is the only UI: a disabled label showing the current track (or a
clickable one when Automation is denied, which deep-links to the Settings pane), and Quit.

## Build and run

```sh
make app          # build + assemble + ad-hoc sign build/Turntable.app
make run          # launch it
make test          # deterministic tests (parse boundary, error mapping)
make bench         # poll cost: round-trip latency vs. main-thread stall
make artwork-bench # cache → network → placeholder fallback, never blank
make tcc-reset     # clear the Automation grant to re-test the permission path
make clean
```

### Signing

Dev builds are **ad-hoc signed** (`SIGN_ID = -`) with the hardened runtime on, because the
`com.apple.security.automation.apple-events` entitlement is only *required* under the
hardened runtime — so dev and release exercise the same Apple Events path.

One consequence: an ad-hoc signature is identified by its cdhash, which changes on every
rebuild, so macOS treats each build as a new app and the Automation grant goes stale. When
polling suddenly reports "Spotify isn't running" after a rebuild, run `make tcc-reset` and
allow the prompt again. This goes away with a real Developer ID certificate.

## Testing without Xcode

`XCTest.framework` ships with Xcode, so `swift test` cannot link here. Tests live in
`Sources/Turntable/Spike/SelfTest.swift` behind a `--selftest` flag, print a pass/fail
summary and exit non-zero on failure, so `make test` works in CI as-is. Worth porting to
swift-testing if a full Xcode gets installed.

## Findings that diverge from Spotify's actual AppleScript behavior

Three corrections, all verified against the real Spotify client on macOS 26.5, and all
still load-bearing since `SpotifyProvider` is unchanged from the original desktop-overlay
version of this app:

1. **`st` is a reserved AppleScript term.** A polling script that opens with
   `set st to player state as text` fails to compile with error **-2741** —
   *"Expected expression but found `st`"* — even standalone, outside any `tell` block. The
   variable is renamed `playerState`. (`tk`, `art` and `d` were each checked and are fine.)

2. **`player position` is locale-formatted.** The position arrives as a string rendered
   with the *user's* decimal separator. On this machine Spotify returned
   `90,271003723145` — a decimal **comma**. `Double("90,271...")` returns `nil`, which
   would have silently pinned position at 0 for every track, on every machine with a comma
   locale. `SpotifyProvider.number(_:)` falls back to a separator-normalized parse, and
   `SelfTest` covers both forms.

3. **A full poll costs 80-95ms**, not sub-millisecond — this is IPC latency on Spotify's
   side, not ours, and identical whether you use `NSAppleScript` or `ScriptingBridge`. Fix:
   `NowPlayingProvider.poll()` is `async`, and `SpotifyProvider` confines the actual
   `executeAndReturnError` call to a private serial `DispatchQueue` — never blocking the
   main thread regardless of round-trip cost. `make bench` confirms: main-thread stall
   during a poll is ~1ms median regardless of round-trip cost.

## Layout

```
Sources/Turntable/
├── main.swift                       # arg dispatch: default is the real app;
│                                      # --selftest/--bench/--artwork-bench run headless
├── AppDelegate.swift                 # wires monitor → artwork → wallpaper, owns lifecycle
├── Wallpaper/
│   └── WallpaperSetter.swift        # writes artwork to a stable file, sets it per NSScreen
├── Window/
│   └── StatusItemController.swift   # the only UI: now-playing label + quit
├── NowPlaying/
│   ├── NowPlayingProvider.swift     # the abstraction; keep it genuinely abstract
│   ├── SpotifyProvider.swift        # the only place Spotify's units/errors exist
│   ├── NowPlayingMonitor.swift      # poll timer, cadence, sleep/wake
│   └── Track.swift
├── Artwork/
│   ├── ArtworkLoader.swift          # cache → disk → network → placeholder
│   └── PlaceholderLibrary.swift     # bundled + user-dropped placeholders
└── Spike/
    ├── SelfTest.swift               # deterministic tests: parsing + error mapping
    ├── PollBench.swift              # poll cost measurement
    └── ArtworkBench.swift           # artwork pipeline acceptance harness

Resources/
└── Placeholders/
    ├── manifest.json
    ├── warm-abstract-01.png         # procedurally generated, 1024×1024, original
    ├── cool-abstract-01.png
    ├── mono-abstract-01.png
    └── moss-abstract-01.png
```

## History

This started as a desktop-overlay clone of a Spotify "now playing" widget — a click-through
window drawn at desktop level with an animated platter/tonearm, artwork, and synced lyrics,
plus a dev window-mode with two extra debug scenes. That was scrapped in favor of the much
smaller feature described above: no window, no motion, no lyrics — just Spotify → the real
desktop wallpaper. The `git` history's first commit is a snapshot of the overlay version, if
any of that is ever worth resurrecting.

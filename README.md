# Turntable

A macOS background app that mirrors whatever is playing in the **Spotify desktop client**
on your desktop: a small album-art + title/artist badge and, when synced lyrics are
available, a Spotify-style lyrics column beneath it. It renders in a click-through window
drawn above your actual wallpaper picture and below Finder's desktop icons, so your own
wallpaper is never touched or replaced. A menu bar item lets you reposition the overlay
(center or any corner) and nudge lyrics sync, alongside the now-playing label and Quit.

## Stack

| | |
|---|---|
| Language | Swift (5.9 language mode, built with the 6.3 toolchain) |
| UI | AppKit (a desktop-level `NSWindow` + `NSStatusItem`) hosting SwiftUI content |
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
backs off when paused/idle, and drives a `PlaybackClock` that interpolates position to
30-60Hz between polls), an `ArtworkLoader` (memory cache → disk cache → network → bundled
placeholder, so there's always an image), and a `LyricsLibrary`.

`LyricsLibrary` resolves the current track to lyrics two ways: a local `.lrc` first, via
`LyricsStore` (indexes `~/Music/Lyrics/`, matches by Spotify track id → `artist - title` →
title); and when nothing local matches, a network fetch from **lrclib.net** via
`LyricsFetcher` — free, keyless, community-sourced synced lyrics. A successful fetch is
cached back to `~/Music/Lyrics/<track-id>.lrc`, so the same track resolves locally (and
offline) on every play after the first. A track with no local or fetched match simply
shows art + title, no empty lyrics column — this is a best-effort convenience, not a
guarantee, since a title/artist/duration mismatch can miss even when lyrics exist for the
track under slightly different metadata.

All of that is rendered by `DesktopContentView` — a small badge (album art + title/artist)
and, when lyrics resolved, `LyricsColumnView` beneath it, bounded to a fixed box rather
than spanning the screen — hosted via `NSHostingView` inside a `DesktopWindow`: a
borderless, click-through `NSWindow` sitting one level below `.desktopIconWindow`, i.e.
above the wallpaper picture and below Finder's icons. Clicks fall straight through to
whatever's actually on the desktop; the window never becomes key, never appears in
Cmd-Tab, and follows every Space.

Two small `@MainActor` settings objects, each backed by `UserDefaults` so they survive a
relaunch:

- **`OverlaySettings`** — where the badge/lyrics block sits: center or any of the four
  corners. Changed from the menu bar's **Position** submenu.
- **`LyricsSyncSettings`** — a manual offset (±5s, 0.25s steps) added to the playback
  position before picking the active lyric line. No amount of polling accuracy fixes a
  systematically biased `.lrc` file, or the small constant lag inherent to a 1Hz poll plus
  Apple Event round-trip — a manual nudge is the standard fix (Musixmatch and Apple Music
  both ship the same control). Adjusted from the menu bar's **Show Lyrics
  Earlier**/**Later**/**Reset** items.

Placeholder artwork is deliberately hidden rather than shown: the real backdrop here is
the user's own wallpaper, so a bundled placeholder graphic would be a worse result than no
artwork view at all.

`StatusItemController` is the only other UI: the now-playing label (or a clickable one
when Automation is denied, which deep-links to the Settings pane), the Position submenu,
the lyrics sync controls, and Quit.

`WallpaperSetter` — write the artwork to a stable file and call
`NSWorkspace.setDesktopImageURL` per `NSScreen` — still exists on disk but is unused. It
was the app's original design (see History below) and is easy to bring back if a
wallpaper-replacement mode is ever wanted alongside the overlay.

## Build and run

```sh
make app          # build + assemble + ad-hoc sign build/Turntable.app
make run          # launch it
make test          # deterministic tests (parsing, clock, LRC, lyrics matching, errors)
make bench         # poll cost: round-trip latency vs. main-thread stall
make artwork-bench # cache → network → placeholder fallback, never blank
make lyrics-bench  # store/parser/active-line sanity against the live current track
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
│                                      # --selftest/--bench/--artwork-bench/--lyrics-bench
│                                      # all run headless
├── AppDelegate.swift                 # wires monitor → desktop window, owns lifecycle
├── Window/
│   ├── DesktopWindow.swift          # borderless NSWindow at desktop level, click-through
│   ├── DesktopContentView.swift     # composes the badge + LyricsColumnView, positioned per OverlaySettings
│   ├── OverlaySettings.swift        # persisted screen position: center or a corner
│   └── StatusItemController.swift   # the only other UI: now-playing label, Position menu, sync controls, quit
├── NowPlaying/
│   ├── NowPlayingProvider.swift     # the abstraction; keep it genuinely abstract
│   ├── SpotifyProvider.swift        # the only place Spotify's units/errors exist
│   ├── NowPlayingMonitor.swift      # poll timer, cadence, sleep/wake, owns PlaybackClock
│   ├── PlaybackClock.swift          # interpolates 1Hz poll position to 30-60Hz
│   └── Track.swift
├── Artwork/
│   ├── ArtworkLoader.swift          # cache → disk → network → placeholder
│   └── PlaceholderLibrary.swift     # bundled + user-dropped placeholders
├── Lyrics/
│   ├── LyricsStore.swift            # indexes ~/Music/Lyrics/, matches id → artist-title → title
│   ├── LyricsLibrary.swift          # local match → network fetch → cache; nil is not an error
│   ├── LyricsFetcher.swift          # fallback fetch from lrclib.net (free, keyless)
│   ├── LyricsSyncSettings.swift     # persisted manual offset applied before line lookup
│   ├── LRCParser.swift              # .lrc → LyricsDocument, standard + word-level (enhanced) LRC
│   ├── LyricsColumnView.swift       # the synced lyrics column: active line bright, scroll, word fill
│   └── WordFill.swift               # karaoke-style fill progress within the active line
├── Wallpaper/
│   └── WallpaperSetter.swift        # unused; writes artwork to a stable file per NSScreen
└── Spike/
    ├── SelfTest.swift               # deterministic tests: parsing, clock, LRC, matching, settings, errors
    ├── PollBench.swift              # poll cost measurement
    ├── ArtworkBench.swift           # artwork pipeline acceptance harness
    └── LyricsBench.swift            # lyrics pipeline acceptance harness (live current track)

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
plus a dev window-mode with two extra debug scenes. That was scrapped in favor of a much
smaller feature: no window, no motion, no lyrics — just Spotify → the real desktop
wallpaper (baseline commit `76708d3`, "Baseline snapshot before wallpaper-only rewrite").

That wallpaper-only design was itself short-lived: the desktop-level window, the artwork +
title layout, and synced lyrics were restored from `76708d3`, while the turntable/platter
scene and its physics/animation code stayed retired. `WallpaperSetter` is kept on disk,
unused, in case a wallpaper-replacement mode is ever wanted as an option alongside the
overlay.

The restored layout then went through a second round of tuning: the original full-width
centered lyrics column was too large for a "just a small overlay, not a wallpaper
takeover" ask, so it shrank to a small badge with a bounded lyrics box; a fixed-position
layout turned into user-adjustable `OverlaySettings` (center or any corner, via the menu
bar) once corner and center placement both needed testing; and lyrics gained a network
fallback (`LyricsFetcher`, lrclib.net) plus a manual `LyricsSyncSettings` offset once
manually curating `.lrc` files per track — and living with whatever timing bias the
fetched file happened to have — proved to be the actual friction, not the lyrics feature
itself.

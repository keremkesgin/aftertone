# Architecture

## Stack

| | |
|---|---|
| Language | Swift (5.9 language mode) |
| UI | AppKit (a desktop-level `NSWindow` + `NSStatusItem`) hosting SwiftUI content |
| Minimum OS | macOS 14.0 |
| Build system | SwiftPM + `Makefile` |
| Dependencies | none |

**Why SwiftPM and not an `.xcodeproj`:** this project is built with Command Line Tools,
no Xcode installed. The CLT toolchain compiles AppKit against the macOS SDK without
trouble, so the package builds a bare executable and the `Makefile` assembles the `.app`
bundle around it — `Info.plist`, `Resources/`, code signature. A SwiftPM package also
opens directly in Xcode if you install it later, so nothing is lost.

## How it works

`AppDelegate` owns a `NowPlayingMonitor` (polls Spotify via AppleScript on a cadence that
backs off when paused/idle, and drives a `PlaybackClock` that interpolates position to
30-60Hz between polls), an `ArtworkLoader` (memory cache → disk cache → network → bundled
placeholder, so there's always an image), and a `LyricsLibrary`.

`LyricsLibrary` resolves the current track to lyrics two ways: a local `.lrc` first, via
`LyricsStore` (indexes `~/Music/Lyrics/`, matches by Spotify track id → `artist - title` →
title); and when nothing local matches, a network fetch from **lrclib.net** via
`LyricsFetcher` — free, keyless, community-sourced synced lyrics. A successful fetch is
cached back to `~/Music/Lyrics/<track-id>.lrc`.

All of that is rendered by `DesktopContentView` — a small badge (album art + title/artist)
and, when lyrics resolved, `LyricsColumnView` beneath it — hosted via `NSHostingView`
inside a `DesktopWindow`: a borderless, click-through `NSWindow` sitting one level below
`.desktopIconWindow`, i.e. above the wallpaper picture and below Finder's icons. Clicks
fall straight through to whatever's actually on the desktop; the window never becomes key,
never appears in Cmd-Tab, and follows every Space. **Vinyl Mode** swaps this badge layout
for `VinylSleeveView` — a spinning-record composition — via `VinylModeSettings`.

### Gradient Wallpaper

`ArtworkPalette.extract` samples a downscaled copy of the current artwork into a few
horizontal-band average colors — cheap enough to run synchronously on every track change.
`GradientWallpaperView` picks the band with the most chroma (saturation × brightness) as
an anchor, then *derives* a near-black, a vivid, and a pale stop from that one hue in HSB
space, rather than trusting the raw (often washed-out) band averages directly — this is
what gives every cover the same dark-to-light sweep instead of a muddy stripe.

The on-screen gradient alone can't reach the menu bar: its legibility scrim is derived
from the wallpaper *file* macOS has on record, not from what's drawn behind it. `WallpaperSetter`
renders the same gradient to an image and sets it as the real desktop picture (alternating
between two stable filenames, since `setDesktopImageURL` is a no-op when called with a URL
that's already set) — so the scrim inherits the same dark top instead of showing a pale
band from whatever wallpaper the user had before. The user's original wallpaper is saved
once and restored automatically when the mode is turned off or the app quits.

### Settings

Small `@MainActor` `ObservableObject`s, each backed by `UserDefaults` so they survive a
relaunch: `OverlaySettings` (badge/lyrics position), `LyricsSyncSettings` (manual offset),
`DisplaySettings` (which screen, resolved by `localizedName` so it survives reconnects),
`AlbumGlowSettings`, `VinylModeSettings`, `GradientWallpaperSettings`.

One correctness note that cost real debugging time: `@Published` fires subscribers on
`willSet`, so a sink that *re-reads the property* instead of using the value handed to it
sees the *previous* value — every menu checkmark and the display-switch logic originally
had this bug (toggle on → no checkmark; toggle off → checkmark appears). The fix is
structural: every settings sink in `StatusItemController` and `AppDelegate` uses the
emitted value directly, never a re-read.

`StatusItemController` is the only other UI: the now-playing label, Position/Display/
Lyrics/Theme submenus, Vinyl Mode and Gradient Wallpaper toggles, **Check for Updates…**,
and Quit.

### Self-updating

`UpdateChecker` fetches `updates/appcast.json` from this repo, compares
`CFBundleVersion` (the integer build number, not the marketing version string — strictly
increasing, so "1.10" can't misjudge itself as older than "1.9"), and if newer, downloads
the release zip and verifies an **Ed25519 signature** over its raw bytes via `CryptoKit`
before touching anything on disk.

This is a hand-rolled analog of what [Sparkle](https://sparkle-project.org) does, not the
framework itself — Sparkle's key-generation and signing tools assume an Xcode-based
workflow, and this project has no Xcode installed. The security property that matters is
reproduced directly with the same primitive (Ed25519): a signature check is what actually
protects an update, not Gatekeeper. A file this app downloads via `URLSession` never gets
the `com.apple.quarantine` attribute a browser download would, so Gatekeeper's
"unidentified developer" check is never in the loop at all — without the signature check,
a compromised release host or a MITM could swap in a malicious payload and this app would
install it with no OS-level check whatsoever.

Once verified, the archive is unzipped (`/usr/bin/unzip` — no archive-handling dependency
for one call site), and the bundle is swapped via a rename-based dance (old bundle staged
aside, new bundle moved into place, old one removed only after the new one is confirmed
in place — never remove-then-move, which would leave nothing at the path if interrupted
mid-swap). The app then `open`s the fresh copy and terminates itself.

## Build and run

```sh
make app          # build + assemble + ad-hoc sign build/Aftertone.app
make run          # launch it
make test         # deterministic tests (parsing, clock, LRC, lyrics matching, gradients, settings)
make bench        # poll cost: round-trip latency vs. main-thread stall
make artwork-bench # cache → network → placeholder fallback, never blank
make lyrics-bench  # store/parser/active-line sanity against the live current track
make tcc-reset    # clear the Automation grant to re-test the permission path
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
summary and exit non-zero on failure, so `make test` works in CI as-is.

## Findings that diverge from Spotify's actual AppleScript behavior

Three corrections, all verified against the real Spotify client on macOS:

1. **`st` is a reserved AppleScript term.** A polling script that opens with
   `set st to player state as text` fails to compile with error **-2741** —
   *"Expected expression but found `st`"* — even standalone, outside any `tell` block. The
   variable is renamed `playerState`.

2. **`player position` is locale-formatted.** The position arrives as a string rendered
   with the *user's* decimal separator. On a comma-locale machine Spotify returned
   `90,271003723145` — `Double("90,271...")` returns `nil`, which would silently pin
   position at 0 for every track. `SpotifyProvider.number(_:)` falls back to a
   separator-normalized parse.

3. **A full poll costs 80-95ms**, not sub-millisecond — IPC latency on Spotify's side, not
   ours. `NowPlayingProvider.poll()` is `async`, and `SpotifyProvider` confines the actual
   AppleScript call to a private serial `DispatchQueue` — never blocking the main thread
   regardless of round-trip cost.

## Layout

```
Sources/Turntable/
├── main.swift                       # arg dispatch: default is the real app;
│                                      # --selftest/--bench/--artwork-bench/--lyrics-bench run headless
├── AppDelegate.swift                 # wires monitor → desktop window, owns lifecycle
├── Window/
│   ├── DesktopWindow.swift          # borderless NSWindow at desktop level, click-through
│   ├── DesktopContentView.swift     # composes badge/vinyl/gradient layers
│   ├── OverlaySettings.swift        # persisted screen position: center or a corner
│   ├── DisplaySettings.swift        # which physical screen, by localizedName
│   └── StatusItemController.swift   # the only other UI: menu bar item + all submenus
├── NowPlaying/
│   ├── NowPlayingProvider.swift     # the abstraction; keep it genuinely abstract
│   ├── SpotifyProvider.swift        # the only place Spotify's units/errors exist
│   ├── NowPlayingMonitor.swift      # poll timer, cadence, sleep/wake, owns PlaybackClock
│   ├── PlaybackClock.swift          # interpolates 1Hz poll position to 30-60Hz
│   └── Track.swift
├── Artwork/
│   ├── ArtworkLoader.swift          # cache → disk → network → placeholder
│   ├── ArtworkPalette.swift         # cheap band-average color sampling
│   └── PlaceholderLibrary.swift     # bundled + user-dropped placeholders
├── Lyrics/
│   ├── LyricsStore.swift            # indexes ~/Music/Lyrics/, matches id → artist-title → title
│   ├── LyricsLibrary.swift          # local match → network fetch → cache; nil is not an error
│   ├── LyricsFetcher.swift          # fallback fetch from lrclib.net (free, keyless)
│   ├── LyricsSyncSettings.swift     # persisted manual offset applied before line lookup
│   ├── LRCParser.swift              # .lrc → LyricsDocument, standard + word-level (enhanced) LRC
│   ├── LyricsColumnView.swift       # the synced lyrics column: active line bright, scroll, word fill
│   └── WordFill.swift               # karaoke-style fill progress within the active line
├── Effects/
│   ├── AlbumGlowView.swift          # blurred corner glow, sampled from artwork
│   ├── AlbumGlowSettings.swift
│   ├── VinylSleeveView.swift        # spinning-record composition
│   ├── VinylModeSettings.swift
│   ├── GradientWallpaperView.swift  # dark→vivid→pale gradient derived from ArtworkPalette
│   └── GradientWallpaperSettings.swift
├── Wallpaper/
│   └── WallpaperSetter.swift        # mirrors the gradient onto the real desktop wallpaper
├── Updates/
│   ├── UpdateChecker.swift          # fetch appcast → verify signature → install → relaunch
│   └── UpdateManifest.swift
└── Spike/
    ├── SelfTest.swift               # deterministic tests
    ├── PollBench.swift
    ├── ArtworkBench.swift
    └── LyricsBench.swift

Resources/
└── Placeholders/
    ├── manifest.json
    └── *.png                        # procedurally generated, original

updates/
└── appcast.json                     # the update manifest UpdateChecker polls

Scripts/
└── sign-release.swift                # signs a release zip with the maintainer's private key
```

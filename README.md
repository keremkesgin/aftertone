# Turntable

A macOS desktop overlay that mirrors whatever is playing in the **Spotify desktop
client** — album artwork and synced lyrics rendered directly on the desktop, behind your
icons, alongside a status-bar menu.

Implemented from `vinyl-spotify-spec.md`, in the phase order that spec defines — with one
deliberate, explicitly-confirmed departure from spec §9: see "Window architecture" below.

## Stack

| | |
|---|---|
| Language | Swift (5.9 language mode, built with the 6.3 toolchain) |
| UI | SwiftUI + AppKit bridging for the window |
| Minimum OS | macOS 14.0 |
| Build system | SwiftPM + `Makefile` |
| Dependencies | none |

**Why SwiftPM and not an `.xcodeproj`:** this machine has Command Line Tools but no
Xcode, so `xcodebuild` is unavailable. The CLT toolchain compiles SwiftUI, AppKit and
ServiceManagement against the macOS SDK without trouble, so the package builds a bare
executable and the `Makefile` assembles the `.app` bundle around it — `Info.plist`,
`Resources/`, code signature. A SwiftPM package also opens directly in Xcode if you
install it later, so nothing is lost.

## Window architecture — desktop overlay, not a floating panel

Spec §9 specifies an `NSPanel` that floats *above* other windows — draggable, focusable,
the standard "desktop widget" pattern (Stats, Bartender, etc.). That was confirmed once,
then explicitly reversed: the wanted behavior is a true desktop overlay — visible as part
of the desktop itself, never a window you click, drag, or bring forward.

That needs a different mechanism entirely: a window sitting at a custom `NSWindow.level`
between the wallpaper picture and Finder's desktop icons, with `ignoresMouseEvents = true`
so every click falls through to whatever's actually on the desktop. SwiftUI's `Window`
scene has no way to set a custom level, so the app no longer uses one — `AppDelegate`
builds the window by hand and hosts SwiftUI content in it via `NSHostingView`.

Confirmed empirically (`CGWindowLevelForKey` on this machine, macOS 26.5):

| Layer | Value | Owner |
|---|---|---|
| Dock (menu bar, actual UI) | 20 | `Dock` |
| Finder desktop icons | -2147483603 | `Finder` |
| **Turntable's window** | **-2147483604** | `Turntable` |
| The wallpaper picture itself | -2147483624 | `Dock` (yes, `Dock` — not `Finder`) |

`DesktopWindow.level = CGWindowLevelForKey(.desktopIconWindow) - 1` lands exactly in the
20-point gap between the wallpaper and the icons — above the picture, below the icons,
confirmed via `CGWindowListCopyWindowInfo` against the real running app, not just the
isolated probe that found the technique. `NSApplication.shared.setActivationPolicy(.accessory)`
plus `LSUIElement=true` in Info.plist keep it out of the Dock and Cmd-Tab

The window itself spans the whole screen (`NSScreen.main!.frame`) — it needs to, since
`NSHostingView` shrinks an `NSWindow` to its content's fitting size the moment it's
assigned as `contentView`, which is what put an earlier version of this in the top-left
corner at a fixed 620×420 instead of covering the desktop. The *visible content* stays a
bounded, centered card, though — filling every pixel with UI would just hide the actual
wallpaper picture, which isn't the goal.
(`app.activationPolicy.rawValue == 1`, confirmed).

The old SwiftUI-`Window`-scene presentation still exists, behind `--window-mode`, purely
as a dev convenience — a normal, draggable, inspectable window for iterating on a scene
without fighting a click-through overlay. It still supports `--debug-scene` /
`--static-scene`. The *default*, no-flags launch is the real desktop overlay.

## Build and run

```sh
make app          # build + assemble + ad-hoc sign build/Turntable.app
make run          # launch the real desktop overlay
make test          # deterministic tests (parse boundary, error mapping, clock, lyrics, ...)
make bench         # poll cost: round-trip latency vs. main-thread stall
make artwork-bench # Phase 3: cache → network → placeholder fallback, never blank
make lyrics-bench  # Phase 7: store/parser/library against the live current track
make spike         # Phase 1: 1Hz provider output
make spike-clock   # Phase 2: 60Hz interpolation with drift diagnostics
make tcc-reset     # clear the Automation grant to re-test the permission path
make clean
```

`SECONDS_ARG=45 make spike` changes the spike duration.

### Why the spikes run the bundled binary

`make spike` runs `build/Turntable.app/Contents/MacOS/Turntable`, not a loose `swift run`
binary. Apple Events are TCC-gated and attributed to the *requesting code's* identity, so
running the bundled, signed executable makes the Automation prompt say "Turntable" and
exercises the real permission path. A loose binary would be attributed to your terminal
instead.

### Signing

Dev builds are **ad-hoc signed** (`SIGN_ID = -`) with the hardened runtime on, because the
`com.apple.security.automation.apple-events` entitlement is only *required* under the
hardened runtime — so dev and release exercise the same Apple Events path.

One consequence: an ad-hoc signature is identified by its cdhash, which changes on every
rebuild, so macOS treats each build as a new app and the Automation grant goes stale. When
polling suddenly reports "Spotify isn't running" after a rebuild, run `make tcc-reset` and
allow the prompt again. This goes away with a real Developer ID certificate (Phase 8).

## Testing without Xcode

`XCTest.framework` ships with Xcode, so `swift test` cannot link here. Tests live in
`Sources/Turntable/Spike/SelfTest.swift` behind a `--selftest` flag, print a pass/fail
summary and exit non-zero on failure, so `make test` works in CI as-is. Worth porting to
swift-testing if a full Xcode gets installed.

## Findings that diverge from the spec

Three corrections, all verified against the real Spotify client on macOS 26.5:

1. **`st` is a reserved AppleScript term.** The polling script in spec §4.3 opens with
   `set st to player state as text`, which fails to compile with error **-2741** —
   *"Expected expression but found `st`"* — even standalone, outside any `tell` block. The
   variable is renamed `playerState`. (`tk`, `art` and `d` were each checked and are fine.)

2. **`player position` is locale-formatted.** Spec §4.1 says to normalize units at the
   parse boundary, which is right, but the position arrives as a string rendered with the
   *user's* decimal separator. On this machine Spotify returned
   `90,271003723145` — a decimal **comma**. `Double("90,271...")` returns `nil`, which
   would have silently pinned position at 0 and parked the tonearm at the lead-in for
   every track, on every machine with a comma locale. `SpotifyProvider.number(_:)` falls
   back to a separator-normalized parse, and `SelfTest` covers both forms.

3. **A full poll costs 80-95ms, not "well under a millisecond."** Spec §4.4 asserts a
   precompiled `NSAppleScript` is cheap enough to run synchronously on the main thread at
   1Hz. `make bench` measures the real Apple Event round trip to Spotify's client at
   80-95ms — this is IPC latency on Spotify's side, not ours, and identical whether you
   use `NSAppleScript` or `ScriptingBridge`. Run on the main thread as specced, this drops
   5+ consecutive 60fps frames once per second — precisely the "obviously broken" jerk
   spec §5 warns about, just from a different cause. Fix: `NowPlayingProvider.poll()` is
   `async`, and `SpotifyProvider` confines the actual `executeAndReturnError` call to a
   private serial `DispatchQueue` — never running concurrently (the only real thread-safety
   requirement `NSAppleScript` has) and never blocking the render thread. `make bench`
   confirms: main-thread stall during a poll is ~1.2ms median regardless of round-trip
   cost.

## Layout

Follows spec §3, with these additions:

```
Sources/Turntable/
├── main.swift                       # arg dispatch: default is the real desktop overlay;
│                                      # --window-mode falls back to the old dev SwiftUI
│                                      # window (still supports --debug-scene/--static-scene)
├── AppDelegate.swift                 # owns the desktop window + status item + lifecycle
├── TurntableApp.swift                # dev-only path (--window-mode); not used by default
├── Window/
│   ├── DesktopWindow.swift          # the desktop-level, click-through NSWindow subclass
│   ├── DesktopContentView.swift     # what actually renders: artwork + lyrics, side by side
│   └── StatusItemController.swift   # menu bar item: now playing, hide/show, quit
├── NowPlaying/
│   ├── NowPlayingProvider.swift     # the abstraction; keep it genuinely abstract
│   ├── SpotifyProvider.swift        # the only place Spotify's units/errors exist
│   ├── NowPlayingMonitor.swift      # poll timer, cadence, sleep/wake  (added)
│   ├── PlaybackClock.swift
│   └── Track.swift
├── Artwork/
│   ├── ArtworkLoader.swift          # cache → disk → network → placeholder
│   └── PlaceholderLibrary.swift     # bundled + user-dropped placeholders
├── Scene/
│   ├── TurntableView.swift          # Phase 4 composite: deck + platter + tonearm
│   ├── PlatterPhysics.swift         # spin-up/coast math, extracted for testing
│   ├── PlatterView.swift            # thin TimelineView wrapper around PlatterPhysics
│   ├── TonearmController.swift      # lead-in/run-out + lift-and-drop state machine
│   ├── TonearmView.swift            # thin wrapper — renders whatever angle it's given
│   ├── BundleImage.swift            # resolves Resources/Scene/*.png (see note below)
│   ├── StaticSceneView.swift        # Phase 3: square artwork, title, artist
│   ├── DebugSceneView.swift         # Phase 1–2 dev surface — kept behind --debug-scene
│   └── StatusBanner.swift           # persistent failure banner  (added)
├── Lyrics/
│   ├── LRCParser.swift              # standard + enhanced LRC, metadata tags, offset
│   ├── LyricsStore.swift            # file location, priority matching, FSEvents watch
│   ├── LyricsLibrary.swift          # ties store + parser together, keyed by track id
│   └── LyricsPanelView.swift        # focus falloff, active-line emphasis, word-fill
└── Spike/
    ├── Spike.swift                  # Phase 1–2 acceptance harness       (added)
    ├── SelfTest.swift               # deterministic tests, all phases   (added)
    ├── PollBench.swift              # poll cost measurement             (added)
    ├── ArtworkBench.swift           # Phase 3 acceptance harness        (added)
    └── LyricsBench.swift            # Phase 7 acceptance harness        (added)

Resources/
├── Placeholders/
│   ├── manifest.json
│   ├── warm-abstract-01.png         # procedurally generated, 1024×1024, original
│   ├── cool-abstract-01.png
│   ├── mono-abstract-01.png
│   └── moss-abstract-01.png
└── Scene/
    ├── deck.png                     # placeholder — real art is Phase 5's job
    ├── tonearm.png
    └── vinyl-grooves.png
```

## Phase status

| Phase | State |
|---|---|
| 0 · Scaffold | done |
| 1 · Data spike | done — verified against the live client |
| 2 · Provider protocol + clock | done |
| 3 · Static scene | done |
| 4 · Motion | built and unit-tested; paused per your request — you're supplying placeholder art |
| 5 · Art pass | not started |
| 6 · Window & menu bar | in progress — desktop-overlay window + status item done; settings, launch-at-login, frame persistence, occlusion handling not yet |
| 7 · Lyrics | parser/store/panel built and tested; live end-to-end check pending (Spotify closed) |
| 8 · Ship | blocked — needs an Apple Developer ID certificate |

### Phase 4 notes (paused)

`PlatterPhysics` (exponential spin-up τ=0.45s / coast τ=1.20s, dt-clamped against display
sleep) and `TonearmController` (lead-in/run-out sweep, two-step async lift-and-drop with
supersession handling) are both extracted from their views specifically so the physics is
unit-testable without rendering — `make test` covers spin-up/coast-down actually differing
mathematically, the display-sleep dt clamp, and the full lift-and-drop sequence including a
superseded-mid-hold case. Wired into `TurntableView` as the default scene.

One real bug found and fixed along the way: the composite's own driving `TimelineView` was
hardcoded `paused: false` — ticking forever regardless of playback state, which is exactly
what spec §7.4 says not to do. Now gated on `isPlaying || isTransitioning || residualDrift`.

Not independently re-verified after that fix (you asked to move on) — the placeholder
`Resources/Scene/*.png` assets are procedurally generated stand-ins; swap them for your own
and the same pipeline should pick them up, since asset loading goes through `BundleImage`'s
`Bundle.main.url(forResource:subdirectory:)` resolver rather than SwiftUI's `Image(_:)`,
which — confirmed empirically — only searches the flat top level of `Resources/`, not
subdirectories like `Resources/Scene/`.

### Phase 7 notes

`make test`'s 129 checks include the LRC parser (standard + enhanced word-level, multi-
timestamp lines, metadata tags, offset, malformed-input safety), `LyricsDocument`'s active-
line/end-of-line queries, `WordFill`'s character-offset fill math, and `LyricsStore`'s
priority matching and normalization (including a live temp-directory integration test) —
all deterministic, no Spotify required.

`make lyrics-bench` additionally round-trips a synthetic `.lrc` against whatever's *actually*
playing on Spotify (real title/artist/unicode, not a fixture), written to a scratch
directory rather than your real `~/Music/Lyrics/`. Spotify got closed partway through this
session's testing, and I didn't reopen it without asking — rerun `make lyrics-bench` with
something playing to get that last live confirmation.

The panel shows automatically whenever a `.lrc` matches the current track and hides
silently otherwise (spec §12) — an explicit menu-bar toggle is Phase 6's job. It's wired
into `TurntableApp` beside whichever scene is active, not inside any one scene view, so
switching `--static-scene`/`--debug-scene`/the default never risks losing it.

Not visually verified — same Screen-Recording limitation as Phase 3's cross-fade.

### Phase 6 notes (in progress)

Done: `DesktopWindow` (desktop-level, click-through), `DesktopContentView` (artwork +
lyrics, hosted via `NSHostingView`), `StatusItemController` (now-playing label, Hide/Show
Deck, Quit — the only interaction surface, since the desktop window itself ignores every
click). See "Window architecture" above for how the level/click-through/no-Dock-icon
claims were verified.

Not yet done, still spec §9/§9.2: Artwork submenu, Speed submenu (doesn't make sense while
Phase 4 is paused), Show Lyrics toggle (currently automatic based on match, per spec §12 —
an explicit override is still worth adding), a real Settings window, frame-origin
persistence with screen-disconnect validation, `NSWindow.occlusionState` handling (moot
right now since the window never occludes anything — nothing above it can occlude a
desktop-level window — but still relevant for *polling* cadence, spec §4.5), and
`SMAppService`-based launch at login.

### Other notes

Phase 8 cannot be completed here: there are no code-signing identities on this machine, so
Developer ID signing, notarization and stapling need your Apple Developer account.

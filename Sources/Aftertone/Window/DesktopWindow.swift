import AppKit

/// A window that renders as part of the desktop itself — above the wallpaper picture,
/// below Finder's desktop icons — rather than floating above other apps' windows.
///
/// This is a deliberate departure from spec §9, which specifies an `NSPanel` floating
/// above other windows (`.floating` level, `canBecomeKey`, draggable by background). That
/// design was confirmed twice, then explicitly reversed: the wanted behavior is a true
/// wallpaper replacement — visible on the desktop, but never a window you interact with,
/// bring forward, or accidentally click.
///
/// Empirically confirmed levels on this machine (`CGWindowLevelForKey`):
/// `.desktopWindow` = -2147483623, `.desktopIconWindow` = -2147483603 — a 20-point gap.
/// Sitting one below `.desktopIconWindow` puts content above the wallpaper picture and
/// below icons, which is the standard technique live-wallpaper-style macOS apps use.
final class DesktopWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        // Present on every Space, don't participate in Mission Control/Exposé grouping,
        // and don't animate in/out like a normal window would.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        // The whole point: clicks must fall through to whatever's actually on the
        // desktop — icons, or apps below. Non-goals (spec §13) already exclude playback
        // controls from the deck, so there is nothing here that ever needs a click.
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Never takes focus, never becomes the active app's main window, never appears
        // in Cmd-Tab or the Dock (the latter is also handled by `LSUIElement`).
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

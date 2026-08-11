import AppKit
import Combine
import CryptoKit
import Foundation

/// Checks GitHub for a newer release, verifies it, and installs it in place.
///
/// This is a hand-rolled analog of what Sparkle (the standard tool for this on macOS —
/// see project README) does, not the framework itself: Sparkle's own key-generation and
/// signing tools assume an Xcode-based workflow, and this project is built entirely with
/// Command Line Tools (see the Makefile's doc comment on `test`) — no Xcode installed.
/// The security property that actually matters is reproduced directly: an Ed25519
/// signature over the release archive's bytes, checked with `CryptoKit` before anything
/// downloaded is trusted, using the same primitive Sparkle itself uses.
///
/// Gatekeeper is deliberately not the concern here. A file this app downloads itself via
/// `URLSession` never gets the `com.apple.quarantine` attribute a browser download would
/// — that flag is what triggers Gatekeeper's "unidentified developer" prompt, and it's
/// simply never applied on this path, Developer ID or not. The signature check below is
/// what stands in for that: without it, a compromised release host or a MITM could swap
/// in an unsigned payload and this app would install it with no OS-level check at all.
@MainActor
final class UpdateChecker: ObservableObject {
    struct AvailableUpdate {
        let manifest: UpdateManifest
    }

    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/keremkesgin/aftertone/main/updates/appcast.json")!

    /// Ed25519 public key, raw 32 bytes, base64. Pairs with the private key used by
    /// `Scripts/sign-release.swift` at release time — that key never leaves the
    /// maintainer's machine and is not in this repo.
    private static let publicKeyBase64 = "SWzhjW9o3szvAR1WsJ1+SBVk1bUnR1rmlLgEKWStkDo="

    private let session = URLSession(configuration: .ephemeral)

    /// Silent unless it finds something — called once at launch. A user-triggered check
    /// (the menu item) always talks, including on failure or "already current".
    func checkSilently() {
        Task { try? await check(announceIfCurrent: false) }
    }

    func checkAndAnnounce() {
        Task { try? await check(announceIfCurrent: true) }
    }

    private func check(announceIfCurrent: Bool) async throws {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let (data, response) = try await session.data(from: Self.manifestURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw Failure.network("server returned an error")
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

            guard Self.isNewer(manifest) else {
                available = nil
                if announceIfCurrent { presentUpToDate() }
                return
            }
            available = AvailableUpdate(manifest: manifest)
            presentAvailable(manifest)
        } catch {
            lastError = String(describing: error)
            if announceIfCurrent { presentFailure(error) }
            throw error
        }
    }

    /// Build number, not the marketing version string — it's the one guaranteed to be a
    /// strictly increasing integer, so this can't misjudge "1.10" as older than "1.9".
    private static func isNewer(_ manifest: UpdateManifest) -> Bool {
        guard let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              let currentBuild = Int(current)
        else { return false }
        return manifest.build > currentBuild
    }

    // MARK: - Install

    /// Downloads the release, verifies its signature, replaces this app's own bundle,
    /// and relaunches — in that order, with the signature check as a hard gate before
    /// anything on disk changes.
    func downloadAndInstall(_ update: AvailableUpdate) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await performInstall(update.manifest)
            } catch {
                lastError = String(describing: error)
                presentFailure(error)
            }
        }
    }

    private func performInstall(_ manifest: UpdateManifest) async throws {
        let (data, response) = try await session.data(from: manifest.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.network("download failed")
        }
        try Self.verify(data, signatureBase64: manifest.signature)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aftertone-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let zipURL = workDir.appendingPathComponent("update.zip")
        try data.write(to: zipURL)

        try Self.unzip(zipURL, into: workDir)
        guard let newBundle = try Self.findAppBundle(in: workDir) else {
            throw Failure.corrupt("release archive did not contain an .app bundle")
        }

        let currentBundlePath = Bundle.main.bundlePath
        try Self.replaceBundle(at: currentBundlePath, with: newBundle.path)
        Self.relaunch(at: currentBundlePath)
    }

    /// Verifies the downloaded bytes were signed by the maintainer's private key — the
    /// entire trust boundary for this feature (see the type's doc comment).
    private static func verify(_ data: Data, signatureBase64: String) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: signatureBase64)
        else {
            throw Failure.corrupt("malformed signature or key")
        }
        guard key.isValidSignature(signature, for: data) else {
            throw Failure.badSignature
        }
    }

    /// Shells out to `/usr/bin/unzip` rather than adding an archive-handling dependency
    /// for one call site — it's already present on every Mac this app runs on.
    private static func unzip(_ zipURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.corrupt("unzip exited with status \(process.terminationStatus)")
        }
    }

    private static func findAppBundle(in directory: URL) throws -> URL? {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return entries.first { $0.pathExtension == "app" }
    }

    /// Swaps the old bundle for the new one via a rename-based dance, not
    /// remove-then-move: a crash between those two steps would otherwise leave nothing
    /// at `path` at all. The staged old bundle is removed only after the new one is
    /// already in place.
    private static func replaceBundle(at path: String, with newPath: String) throws {
        let fm = FileManager.default
        let staged = path + ".old-\(UUID().uuidString)"
        try fm.moveItem(atPath: path, toPath: staged)
        do {
            try fm.moveItem(atPath: newPath, toPath: path)
        } catch {
            // Best-effort rollback so a failed install doesn't leave the app missing.
            try? fm.moveItem(atPath: staged, toPath: path)
            throw error
        }
        try? fm.removeItem(atPath: staged)
    }

    /// `open` a fresh copy at `path`, then quit — not `NSWorkspace.launchApplication`
    /// directly on self, which fights the process currently tearing itself down.
    private static func relaunch(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - User-facing feedback
    //
    // `LSUIElement` means there's no window to anchor a sheet to, and this app has no
    // other UI surface than the status item — a plain `NSAlert` is the simplest thing
    // that reliably appears in front of whatever the user is doing.

    private func presentAvailable(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Aftertone \(manifest.version) is available"
        alert.informativeText = manifest.notes.isEmpty
            ? "You're on an older version. Install the update now?"
            : "\(manifest.notes)\n\nInstall the update now?"
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(AvailableUpdate(manifest: manifest))
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Aftertone is on the latest version."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    enum Failure: Error, CustomStringConvertible {
        case network(String)
        case badSignature
        case corrupt(String)

        var description: String {
            switch self {
            case .network(let reason): "Network error: \(reason)"
            case .badSignature: "The downloaded update's signature did not match — refusing to install it."
            case .corrupt(let reason): "The update archive was invalid: \(reason)"
            }
        }
    }
}

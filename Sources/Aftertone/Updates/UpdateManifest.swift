import Foundation

/// One release, as published in `updates/appcast.json` on GitHub. Deliberately not
/// Sparkle's appcast XML format — this app hand-rolls the update channel (see
/// `UpdateChecker`'s doc comment for why), so a small flat JSON is simpler than
/// reproducing RSS.
struct UpdateManifest: Decodable {
    let version: String
    let build: Int
    let downloadURL: URL
    /// Base64 Ed25519 signature over the raw bytes of the zip at `downloadURL`. Verified
    /// against `UpdateChecker.publicKey` before anything downloaded is ever installed —
    /// this is the actual security boundary, not Gatekeeper (see `UpdateChecker`).
    let signature: String
    let notes: String

    private enum CodingKeys: String, CodingKey {
        case version, build, notes
        case downloadURL = "url"
        case signature = "sha256Signature"
    }
}

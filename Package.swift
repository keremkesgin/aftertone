// swift-tools-version:5.9
import PackageDescription

// The app bundle is assembled by the Makefile, not by SwiftPM — see Bundle/Info.plist
// and `make app`. SwiftPM only produces the bare executable. This keeps Resources/ as
// loose files inside Contents/Resources (spec §6.2) instead of an SPM resource bundle.
let package = Package(
    name: "Turntable",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Turntable",
            path: "Sources/Turntable"
        )
    ]
)

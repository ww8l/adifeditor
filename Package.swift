// swift-tools-version: 6.0
import PackageDescription

// The app target arrived once the round-trip tests passed (DESIGN.md §13), not before.
//
// `swift build` produces a bare executable, which is not enough on its own: a
// document-based app needs a bundle for its Info.plist, and Apple Silicon refuses to
// run an unsigned arm64 binary at all (§12). `Scripts/bundle.sh` does both.
//
// No dependencies. Ever. See DESIGN.md §5.
let package = Package(
    name: "ADIFEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ADIFKit", targets: ["ADIFKit"]),
        .library(name: "POTAKit", targets: ["POTAKit"]),
        .library(name: "QRZKit", targets: ["QRZKit"]),
        .executable(name: "ADIFEditor", targets: ["ADIFEditor"])
    ],
    targets: [
        .target(
            name: "ADIFKit"
        ),
        // POTA is its own layer (§7), not part of ADIFKit: the format knows nothing
        // about parks, and a park reference is not an ADIF concept.
        .target(
            name: "POTAKit",
            dependencies: ["ADIFKit"]
        ),
        // The only target permitted to open a socket (§6.5, as amended 2026-08-14).
        // Everything in it above `QRZTransport` is reachable in tests with no network,
        // and the suite must never make a real request.
        .target(
            name: "QRZKit",
            dependencies: ["ADIFKit"]
        ),
        .executableTarget(
            name: "ADIFEditor",
            dependencies: ["ADIFKit", "POTAKit", "QRZKit"]
        ),
        .testTarget(
            name: "POTAKitTests",
            dependencies: ["POTAKit", "ADIFKit"]
        ),
        .testTarget(
            name: "QRZKitTests",
            dependencies: ["QRZKit", "ADIFKit"]
        ),
        .testTarget(
            name: "ADIFKitTests",
            dependencies: ["ADIFKit"]
        )
    ]
)

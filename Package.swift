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
        .executable(name: "ADIFEditor", targets: ["ADIFEditor"])
    ],
    targets: [
        .target(
            name: "ADIFKit"
        ),
        .executableTarget(
            name: "ADIFEditor",
            dependencies: ["ADIFKit"]
        ),
        .testTarget(
            name: "ADIFKitTests",
            dependencies: ["ADIFKit"]
        )
    ]
)

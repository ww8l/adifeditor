// swift-tools-version: 6.0
import PackageDescription

// ADIFKit is deliberately the only target that exists right now. The app target is
// added once the round-trip tests pass (DESIGN.md §13) — not before.
//
// No dependencies. Ever. See DESIGN.md §5.
let package = Package(
    name: "ADIFEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ADIFKit", targets: ["ADIFKit"])
    ],
    targets: [
        .target(
            name: "ADIFKit"
        ),
        .testTarget(
            name: "ADIFKitTests",
            dependencies: ["ADIFKit"]
        )
    ]
)

import Foundation

/// Locates the committed fixture corpus.
///
/// Found relative to this source file rather than through `Bundle.module`, so the
/// fixtures stay at the repo root where a human can look at them, and so the suite runs
/// under a plain `swift test` from the command line (DESIGN.md §7).
enum Fixtures {
    static let root: URL = {
        URL(fileURLWithPath: #filePath)          // .../Tests/ADIFKitTests/Fixtures.swift
            .deletingLastPathComponent()         // .../Tests/ADIFKitTests
            .deletingLastPathComponent()         // .../Tests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent("fixtures")
    }()

    /// Every fixture file, real and synthetic. Excludes documentation.
    static var all: [URL] {
        (real + synthetic).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var real: [URL] { files(in: "real") }
    static var synthetic: [URL] { files(in: "synthetic") }

    private static func files(in directory: String) -> [URL] {
        let dir = root.appendingPathComponent(directory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter {
            // Dotfiles are excluded rather than fed to the parser. A `.DS_Store` — which
            // the Finder drops into any directory a human opens — is not UTF-8, so it
            // fails five tests at once with a parser-shaped error that has nothing to do
            // with the parser.
            $0.lastPathComponent != "README.md"
                && !$0.lastPathComponent.hasPrefix(".")
                && !$0.hasDirectoryPath
        }
    }

    static func data(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Fixtures whose defect forces the writer to change bytes, so they are held to
    /// parse-equality rather than byte-identity. The change is confined to the defect:
    /// a corrected LENGTH, or a terminator supplied for a record that lost one.
    static let byteIdentityExempt: Set<String> = [
        "bad-length-short.adi",
        "bad-length-long.adi",
        "huge-length.adi",
        "length-as-bytes.adi",
        "truncated.adi",
        "truncated-tag.adi",
        "unparseable-length.adi",
        "tag-inside-value.adi",
        "truncated-terminator.adi",
    ]

    /// Fixtures expected to produce at least one warning.
    ///
    /// A superset of `byteIdentityExempt`: `text-between-fields.adi` is irregular
    /// enough to warn about, but the stray text is preserved verbatim, so it still
    /// round-trips byte for byte. Warning and rewriting are separate things.
    static let expectedToWarn: Set<String> = byteIdentityExempt.union([
        "duplicate-field.adi",
        "html-error-page.adi",
        "separator-between-fields.adi",
        "stray-bracket.adi",
        "text-between-fields.adi",
    ])

    /// The one fixture that must refuse to open.
    static let fatal: Set<String> = ["invalid-utf8.adi"]

    static func isByteIdentityExempt(_ url: URL) -> Bool {
        byteIdentityExempt.contains(url.lastPathComponent)
    }

    static func isExpectedToWarn(_ url: URL) -> Bool {
        expectedToWarn.contains(url.lastPathComponent)
    }

    static func isFatal(_ url: URL) -> Bool {
        fatal.contains(url.lastPathComponent)
    }
}

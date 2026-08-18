import Testing
import Foundation
@testable import QRZKit

/// §6.5's conditions, as tests rather than as a comment.
///
/// The original rule was "no network", and what made it strong was that the OS enforced
/// it: without `com.apple.security.network.client` in the entitlements, a sandboxed app
/// simply cannot open a socket. Decision 17 traded that for the QRZ lookup, and CLAUDE.md
/// is explicit about what is left — "this list and §11's tests are what remain". Until
/// now the list existed only as a comment in `Support/ADIFEditor.entitlements`, which is
/// discipline, not a gate: nothing failed if someone added a second destination.
///
/// These read the repository itself, so they hold for the shipped bundle rather than for
/// a mock of it, and they run on every push through the pre-push hook.
@Suite("§6.5's network conditions")
struct NetworkConditionsTests {

    /// The repo root, found relative to this file — the same trick `Fixtures` uses, and
    /// for the same reason: no bundle resources, and it works under a plain `swift test`.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/QRZKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static func entitlements() throws -> [String: Any] {
        let url = root.appendingPathComponent("Support/ADIFEditor.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data,
                                                              format: nil)
        return plist as? [String: Any] ?? [:]
    }

    /// Every `.swift` file the app is built from.
    private static func sources() throws -> [(name: String, text: String)] {
        let sources = root.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources,
                                                        includingPropertiesForKeys: nil)
        var files: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    @Test("the app never asks to listen")
    func noServerEntitlement() throws {
        // The half of the original rule that survived decision 17 untouched. Read as a
        // plist rather than grepped, because the file's own comment says the words.
        let keys = try Self.entitlements().keys
        #expect(!keys.contains("com.apple.security.network.server"))
    }

    @Test("the entitlements are exactly the three that were argued for")
    func entitlementsAreTheAgreedThree() throws {
        // Not "contains" — equals. A fourth entitlement is a decision, and it should have
        // to be made here as well as in the plist.
        let keys = Set(try Self.entitlements().keys)
        #expect(keys == ["com.apple.security.app-sandbox",
                         "com.apple.security.files.user-selected.read-write",
                         "com.apple.security.network.client"])
    }

    @Test("one network destination, and it is QRZ's")
    func onlyQRZIsReachable() throws {
        // "network.client is for QRZ's XML service and nothing else" — an update check, a
        // callsign database, a POTA API or any telemetry would be a new decision needing
        // the same conversation, not a free ride on this key (decision 17).
        //
        // Whole-line comments are dropped first: doc comments in the scanner quote
        // `<a href="http://example.com/x">` as an example of what a failed download looks
        // like, which is prose about markup, not a destination.
        for (name, text) in try Self.sources() {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }

                for host in Self.hosts(in: String(line)) {
                    #expect(host == "xmldata.qrz.com",
                            "\(name) reaches \(host); §6.5 permits one destination")
                }
            }
        }
    }

    /// The hosts of any `http://` or `https://` URL on a line. Written out rather than
    /// using `Regex`, so what counts as a host is visible rather than encoded.
    private static func hosts(in line: String) -> [String] {
        var found: [String] = []
        for scheme in ["https://", "http://"] {
            var rest = Substring(line)
            while let start = rest.range(of: scheme) {
                let after = rest[start.upperBound...]
                let host = after.prefix { character in
                    !"/\"' \t)>".contains(character)
                }
                if !host.isEmpty { found.append(String(host)) }
                rest = after
            }
        }
        return found
    }

    @Test("and that destination is what the session actually uses")
    func theSessionUsesThatHost() {
        #expect(QRZSession.defaultBaseURL.host() == "xmldata.qrz.com")
        #expect(QRZSession.defaultBaseURL.scheme == "https", "credentials travel in the URL")
    }
}

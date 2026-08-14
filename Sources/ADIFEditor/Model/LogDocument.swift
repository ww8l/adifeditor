import AppKit
import ADIFKit

/// One open ADIF file.
///
/// Deliberately thin: the parse and the serialization both live in ADIFKit, and this
/// class exists to hand `Data` between AppKit and that. The round-trip guarantee
/// (§6.2a) holds here only because nothing in this file touches the parsed model on the
/// way through — `data(ofType:)` writes back exactly what `read(from:)` produced until
/// the user edits something.
/// `@objc` with an explicit name because `Info.plist`'s `NSDocumentClass` is looked up
/// through the Objective-C runtime, and a Swift class is registered under a mangled,
/// module-qualified name that the plist would otherwise have to spell exactly.
@objc(LogDocument)
final class LogDocument: NSDocument {

    private(set) var log = ADIFDocument()

    /// Problems the parser recovered from while opening this file. Surfaced by the
    /// window controller rather than thrown, because the file did open (§6.4).
    private(set) var warnings: [ADIFWarning] = []

    // MARK: - Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        let parsed: ADIFDocument
        do {
            parsed = try ADIFParser.parse(data)
        } catch let error as ADIFParseError {
            throw error.asPresentableError()
        }

        // Both accessors are `nonisolated` because `NSDocument`'s are, but AppKit only
        // moves reading and writing off the main thread when a document opts in, and
        // this one does not (see `canConcurrentlyReadDocuments` below). Asserting the
        // isolation states that invariant rather than disabling the check.
        MainActor.assumeIsolated {
            log = parsed
            warnings = parsed.warnings
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated { ADIFWriter.write(log) }
    }

    /// Left off deliberately, and the isolation assertions in `read(from:ofType:)`
    /// depend on it: concurrent reading is what would put a parse on a background
    /// thread. A 100k-QSO log is the case for turning it on, and §14 wants that
    /// measured in M2 before anything is optimized for it.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        false
    }

    /// Off, and it must stay off. Autosave-in-place rewrites the file the user opened
    /// without them asking, which is precisely what §6.1 forbids: the original is not
    /// touched unless Save is explicitly invoked.
    override class var autosavesInPlace: Bool { false }

    /// The extension a logger chose is not evidence of anything — FT8CN writes ADIF
    /// content to `.txt` (decision 13). The app judges by content and opens what it is
    /// given, so the open panel must not grey those files out.
    override class var readableTypes: [String] {
        ["com.ww8l.adifeditor.adi", "public.plain-text", "public.data"]
    }

    override class func isNativeType(_ type: String) -> Bool { true }

    // MARK: - Windows

    override func makeWindowControllers() {
        addWindowController(LogWindowController(document: self))
    }
}

private extension ADIFParseError {
    /// Wraps the parse failure in an `NSError` so AppKit's document machinery presents
    /// it as an alert naming the problem and its offset, rather than a stack trace.
    func asPresentableError() -> NSError {
        let recovery: String
        switch self {
        case .invalidUTF8:
            recovery = "ADIF files must be UTF-8 text. This one contains a byte sequence "
                     + "that is not valid UTF-8, so opening it would mean guessing at "
                     + "what those bytes mean. Repair the file in a text editor first."
        }

        return NSError(
            domain: "com.ww8l.adifeditor",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: description,
                NSLocalizedRecoverySuggestionErrorKey: recovery
            ]
        )
    }
}

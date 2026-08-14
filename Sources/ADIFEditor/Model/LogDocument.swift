import AppKit
import ADIFKit

/// One open ADIF file.
///
/// Deliberately thin: the parse and the serialization both live in ADIFKit, and this
/// class exists to hand `Data` between AppKit and that. The round-trip guarantee
/// (§6.2a) holds here only because nothing in this file touches the parsed model on the
/// way through — `data(ofType:)` writes back exactly what `read(from:)` produced until
/// the user edits something.
///
/// Every mutation goes through `replaceRecord(at:with:actionName:)`, which is the only
/// place `log` changes after a parse. That is what keeps undo honest: one primitive to
/// register, so no edit can reach the model without also becoming undoable.
///
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

    // MARK: - Editing

    /// Posted after any change to `log`, including undo and redo, so views can catch up
    /// without every mutation site having to remember to tell them.
    ///
    /// `userInfo[changedRowKey]` carries the record index that changed, when exactly one
    /// did. Its absence means the whole list moved — a sort, a deletion — and the view
    /// should redraw everything.
    static let recordsDidChange = Notification.Name("LogDocumentRecordsDidChange")
    static let changedRowKey = "changedRow"

    /// Sets one cell, which is one field of one record.
    ///
    /// What the edit means to the data — clearing removes the field, an added field
    /// takes the file's own spelling — is ADIFKit's to decide and is tested there. This
    /// only wraps the result in undo.
    func setValue(_ newValue: String, forColumn column: String, inRecordAt index: Int) {
        guard let edited = log.recordBySettingValue(newValue,
                                                    forColumn: column,
                                                    inRecordAt: index) else { return }
        replaceRecord(at: index, with: edited, actionName: "Edit \(column)")
    }

    /// The single undoable mutation. Everything that changes a record goes through here.
    ///
    /// Undo restores the whole record rather than the one field's text, because a field
    /// carries its position, its spelling and its trailing separator, and a cleared field
    /// that was re-added from a string alone would come back in the wrong place with the
    /// wrong casing. Editing a cell and undoing it has to leave the file byte-identical
    /// (§6.2a), and only a snapshot gets that right.
    func replaceRecord(at index: Int, with record: ADIFRecord, actionName: String) {
        guard log.records.indices.contains(index) else { return }

        let previous = log.records[index]
        guard previous != record else { return }

        undoManager?.registerUndo(withTarget: self) { document in
            // Registering during undo is what gives redo for free: AppKit routes this
            // second registration onto the redo stack.
            document.replaceRecord(at: index, with: previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)

        log.records[index] = record

        NotificationCenter.default.post(
            name: Self.recordsDidChange,
            object: self,
            userInfo: [Self.changedRowKey: index]
        )
    }

    /// Reorders the log by one column.
    ///
    /// A sort is an edit. It changes the order records will be written in, so it marks
    /// the document dirty and is undoable — but it reaches the file only when Save is
    /// pressed (§6.1, owner's ruling), like every other change.
    func sortRecords(byColumn column: String, ascending: Bool) {
        replaceAllRecords(log.recordsSorted(byColumn: column, ascending: ascending),
                          actionName: "Sort by \(column)")
    }

    /// Deletes rows. The one destructive operation in the app, and undoable like the rest.
    func deleteRecords(at indexes: IndexSet) {
        guard !indexes.isEmpty else { return }

        let name = indexes.count == 1 ? "Delete QSO" : "Delete \(indexes.count) QSOs"
        replaceAllRecords(log.recordsByDeleting(at: indexes), actionName: name)
    }

    /// The undoable mutation for changes that move or remove whole records, as opposed to
    /// `replaceRecord`, which edits one in place.
    ///
    /// Snapshots the entire list. That is the honest cost of undoable sorting: the order
    /// is the thing being changed, so there is nothing smaller to remember.
    func replaceAllRecords(_ records: [ADIFRecord], actionName: String) {
        let previous = log.records
        guard previous != records else { return }

        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceAllRecords(previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)

        log.records = records

        NotificationCenter.default.post(name: Self.recordsDidChange, object: self)
    }

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

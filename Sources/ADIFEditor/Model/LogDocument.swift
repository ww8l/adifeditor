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

    /// Every column this document has shown, in the order the grid shows them.
    ///
    /// Only ever grows, exactly like the grid's own columns. That is the point: a column
    /// whose last remaining value is cleared leaves the *file*, so `log.columnNames` can
    /// no longer say where it belonged — and retyping the value would append the field to
    /// the end of the record, changing bytes nobody edited (§6.2a) and moving the column
    /// to the far right on the next open. Remembering the order for the life of the
    /// window is what a spreadsheet does, and it costs one array.
    private(set) var columnOrder: [String] = []

    /// Problems the parser recovered from while opening this file. Surfaced by the
    /// window controller rather than thrown, because the file did open (§6.4).
    private(set) var warnings: [ADIFWarning] = []

    /// The column the records are in order by, if a sort put them there, and `nil` if
    /// they are in the order the file gave them or an edit has since broken it.
    ///
    /// Part of the undoable state rather than the view's own memory, because the sort
    /// *is* a change to the records (see `sortRecords`) and undoing it puts them back.
    /// A header arrow the undo does not clear claims a sort that is not in effect, and
    /// the next click on that header then reverses a sort that was undone — it goes
    /// descending where the visible arrow says it should go ascending.
    private(set) var sortedBy: Sort?

    struct Sort: Equatable {
        let column: String
        let ascending: Bool
    }

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
            columnOrder = parsed.columnNames
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
        rememberColumns()
        guard let edited = log.recordBySettingValue(newValue,
                                                    forColumn: column,
                                                    inRecordAt: index,
                                                    columnOrder: columnOrder) else { return }
        replaceRecord(at: index, with: edited, actionName: "Edit \(column)")
    }

    /// Folds any column the log has gained into the remembered order, in the place the
    /// records give it. Pasted QSOs can carry a field nothing else in the file had.
    private func rememberColumns() {
        let current = log.columnNames
        guard current != columnOrder else { return }

        var merged = columnOrder
        var anchor = -1
        for name in current {
            if let known = merged.firstIndex(of: name) {
                anchor = known
                continue
            }
            merged.insert(name, at: anchor + 1)
            anchor += 1
        }
        columnOrder = merged
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

        // Typing a new value into the column the log is sorted on can put that row out of
        // order without moving it, so the header would go on claiming an order that no
        // longer holds. Conservative on purpose: an edit that happens to leave the order
        // intact still clears the arrow, because knowing better would mean re-sorting the
        // whole log on every keystroke to answer a question about one arrow.
        let stillSorted = sortedBy.map { record[$0.column] == log.records[index][$0.column] }
            ?? false

        replaceRecord(at: index, with: record, actionName: actionName,
                      sortedBy: stillSorted ? sortedBy : nil)
    }

    /// The same edit with the resulting order stated rather than inferred, which is what
    /// undo needs: restoring the record and restoring the arrow have to happen before the
    /// notification goes out, or the grid redraws against half-restored state.
    private func replaceRecord(at index: Int,
                               with record: ADIFRecord,
                               actionName: String,
                               sortedBy newSort: Sort?) {
        guard log.records.indices.contains(index) else { return }

        let previous = log.records[index]
        let previousSort = sortedBy
        guard previous != record else { return }

        undoManager?.registerUndo(withTarget: self) { document in
            // Registering during undo is what gives redo for free: AppKit routes this
            // second registration onto the redo stack.
            document.replaceRecord(at: index, with: previous, actionName: actionName,
                                   sortedBy: previousSort)
        }
        undoManager?.setActionName(actionName)

        log.records[index] = record
        sortedBy = newSort

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
                          actionName: "Sort by \(column)",
                          sortedBy: Sort(column: column, ascending: ascending))
    }

    /// Deletes rows. The one destructive operation in the app, and undoable like the rest.
    func deleteRecords(at indexes: IndexSet) {
        guard !indexes.isEmpty else { return }

        let name = indexes.count == 1 ? "Delete QSO" : "Delete \(indexes.count) QSOs"
        // Removing rows from a sorted list leaves a sorted list, so the header keeps its
        // arrow — deleting a QSO is not a reason for the grid to forget how it is ordered.
        replaceAllRecords(log.recordsByDeleting(at: indexes), actionName: name,
                          sortedBy: sortedBy)
    }

    /// Inserts QSOs at a row, and reports where they landed so the grid can select them.
    ///
    /// Additive (§6.3): pasted records join the log, they never overwrite the ones there.
    @discardableResult
    func insertRecords(_ incoming: [ADIFRecord], at index: Int, actionName: String) -> IndexSet {
        guard !incoming.isEmpty else { return IndexSet() }

        let position = min(max(index, 0), log.records.count)
        var records = log.records
        records.insert(contentsOf: incoming, at: position)

        // Pasted QSOs land where the cursor is, not where the sort would put them, so
        // whatever order held before this no longer does.
        replaceAllRecords(records, actionName: actionName, sortedBy: nil)
        return IndexSet(integersIn: position..<(position + incoming.count))
    }

    /// The undoable mutation for changes that move or remove whole records, as opposed to
    /// `replaceRecord`, which edits one in place.
    ///
    /// Snapshots the entire list. That is the honest cost of undoable sorting: the order
    /// is the thing being changed, so there is nothing smaller to remember.
    /// `sortedBy` is the order the new list is in, and it is snapshotted and restored
    /// alongside the records for the same reason they are: it is part of what the change
    /// changed, so undo has to put it back too. Callers that break the order pass `nil`.
    func replaceAllRecords(_ records: [ADIFRecord],
                           actionName: String,
                           sortedBy newSort: Sort?) {
        let previous = log.records
        let previousSort = sortedBy
        guard previous != records else { return }

        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceAllRecords(previous, actionName: actionName,
                                       sortedBy: previousSort)
        }
        undoManager?.setActionName(actionName)

        log.records = records
        sortedBy = newSort

        NotificationCenter.default.post(name: Self.recordsDidChange, object: self)
    }

    // MARK: - Pending edits

    /// Ends any cell edit still in a field editor across this document's windows.
    ///
    /// See `GridViewController.commitPendingEdit` for why this is needed at all. It is
    /// wired in three places rather than one because AppKit reaches saving by three
    /// routes: the Save menu item, the close-and-save prompt, and the `NSEditor`
    /// protocol the document machinery uses before both.
    @discardableResult
    func commitPendingEdits() -> Bool {
        for controller in windowControllers {
            if let log = controller as? LogWindowController, !log.commitPendingEdit() {
                return false
            }
        }
        return true
    }

    /// ⌘S. `saveDocument:` is not an action the field editor handles, so the key
    /// equivalent walks straight past it up the responder chain and the edit on screen
    /// never reaches `log`. The file was written without it and then marked clean.
    override func save(_ sender: Any?) {
        commitPendingEdits()
        super.save(sender)
    }

    override func saveAs(_ sender: Any?) {
        commitPendingEdits()
        super.saveAs(sender)
    }

    override func saveTo(_ sender: Any?) {
        commitPendingEdits()
        super.saveTo(sender)
    }

    /// Closing. AppKit asks this before deciding whether to put up the save-changes
    /// prompt, so an uncommitted edit has to land in `log` first — otherwise a document
    /// whose only change is the cell on screen is judged clean and closed without a word.
    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        commitPendingEdits()
        super.canClose(withDelegate: delegate,
                       shouldClose: shouldCloseSelector,
                       contextInfo: contextInfo)
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

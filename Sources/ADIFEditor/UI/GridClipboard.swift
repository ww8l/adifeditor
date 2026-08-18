import AppKit
import ADIFKit

/// Cut, copy and paste for the grid.
///
/// **Rows, not cells.** The grid selects whole QSOs — that is what `NSTableView`
/// selection is — so these operate on QSOs. A spreadsheet copies the rectangle you have
/// highlighted; here the highlight is always whole rows, and pretending otherwise would
/// mean inventing a cell selection model that nothing else in the app has. While a cell
/// is *being edited* the field editor is first responder and AppKit's own text cut, copy
/// and paste apply to the text, which is the behaviour you would expect there.
///
/// **The clipboard format is ADI**, the only format this app speaks (§3). Copied QSOs go
/// on the pasteboard as ADIF text, so they paste back into this app, into another log, or
/// into a text editor, and nothing else has to be invented to carry them.
extension GridViewController {

    // MARK: - Actions

    @objc func copy(_ sender: Any?) {
        copyRows(targetRows(for: sender))
    }

    @objc func cut(_ sender: Any?) {
        let rows = targetRows(for: sender)
        guard !rows.isEmpty else { return }

        copyRows(rows)
        document.deleteRecords(at: rows)
        tableView.deselectAll(nil)
    }

    @objc func paste(_ sender: Any?) {
        let incoming = Self.recordsOnPasteboard()
        guard !incoming.isEmpty else {
            // Nothing parseable. §6.4: say so quietly rather than crashing or silently
            // doing nothing that looks like a bug.
            NSSound.beep()
            return
        }

        // Land below the selection, which is where a spreadsheet puts pasted rows. With
        // nothing selected they go at the end rather than the top, so pasting one log
        // into another appends it.
        let rows = targetRows(for: sender)
        let insertionPoint = (rows.last.map { $0 + 1 }) ?? tableView.numberOfRows

        let name = incoming.count == 1 ? "Paste QSO" : "Paste \(incoming.count) QSOs"
        let landed = document.insertRecords(incoming, at: insertionPoint, actionName: name)

        tableView.selectRowIndexes(landed, byExtendingSelection: false)
        if let first = landed.first { tableView.scrollRowToVisible(first) }
    }

    // MARK: - Pasteboard

    private func copyRows(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }

        let records = rows.compactMap { row -> ADIFRecord? in
            document.log.records.indices.contains(row) ? document.log.records[row] : nil
        }

        // No header: this is a fragment of a log, not a log. A header carried along would
        // be a second one when the fragment is pasted into a file that already has its
        // own, and the writer would faithfully emit both.
        let fragment = ADIFDocument(header: nil, records: records)
        let text = String(decoding: ADIFWriter.write(fragment), as: UTF8.self)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// QSOs on the pasteboard, or empty if it holds nothing this app understands.
    ///
    /// Parse failures are not errors here. The pasteboard belongs to the whole system and
    /// will routinely hold a URL or a paragraph of prose; that is a disabled Paste, not a
    /// diagnostic.
    static func recordsOnPasteboard() -> [ADIFRecord] {
        guard let text = NSPasteboard.general.string(forType: .string),
              let parsed = try? ADIFParser.parse(Data(text.utf8))
        else { return [] }

        return parsed.records
    }

    /// Whether the pasteboard looks like it holds QSOs, for menu enablement.
    ///
    /// Deliberately a cheap test rather than a parse: menu validation runs on every
    /// keystroke of the menu bar, and the pasteboard can hold a very large string.
    ///
    /// Cheap has to mean cheap. This read `text.uppercased().contains("<EOR>")`, which
    /// allocates a second copy of the whole pasteboard only to throw it away — and the
    /// large string the comment worries about is one this app puts there itself, since
    /// Copy on a selected log is exactly that.
    ///
    /// The obvious replacement, `range(of:options:.caseInsensitive)`, is worse rather
    /// than better: measured on 4 MB it wins the case where the terminator is near the
    /// top (0.04 ms against 1.24) and loses the case where there is none to find
    /// (290 ms against 73). A miss is not the rare case here — it is every time the
    /// pasteboard holds something that is not a log, which is most of the time, and 290 ms
    /// is a menu that visibly hangs. Case-insensitive `Comparator` folding over Unicode
    /// is what costs; `<EOR>` is five ASCII bytes and needs none of it.
    static var pasteboardLooksLikeADIF: Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        return holdsRecordTerminator(text)
    }

    /// Whether `<EOR>` appears, in any casing, without copying the string.
    ///
    /// One pass over the UTF-8 bytes, folding only ASCII letters, so nothing is allocated
    /// and a hit returns at the terminator rather than at the end. On the same 4 MB it is
    /// 0.00 ms for a log and 16 ms for a 4 MB string that is not one.
    ///
    /// The restart rule is the whole of Knuth–Morris–Pratt for this needle: `<EOR>` has no
    /// proper prefix that is also a suffix except the opening `<`, so a byte that breaks
    /// the match either starts a new one or does not.
    private static func holdsRecordTerminator(_ text: String) -> Bool {
        let terminator = Array("<EOR>".utf8)
        var matched = 0

        for byte in text.utf8 {
            // Continuation bytes of a multi-byte character are >= 0x80 and so are never
            // folded, which is what makes a byte-level pass safe on arbitrary UTF-8.
            let folded = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                ? byte - 32
                : byte

            if folded == terminator[matched] {
                matched += 1
                if matched == terminator.count { return true }
            } else {
                matched = folded == terminator[0] ? 1 : 0
            }
        }

        return false
    }

    // MARK: - Target

    /// The rows an action applies to: the ones the context menu captured when it opened,
    /// or the selection when the action came from anywhere else.
    ///
    /// Identity of the sending menu decides it, not merely that a menu sent it. The Edit
    /// menu's Copy and the context menu's Copy arrive at the same method as `NSMenuItem`s,
    /// and `contextRows` still holds whatever the last right-click captured — so testing
    /// only for "a menu item sent this" would let a stale right-click silently redirect
    /// an Edit-menu action to rows the user is no longer pointing at.
    private func targetRows(for sender: Any?) -> IndexSet {
        if let item = sender as? NSMenuItem, item.menu === rowMenu {
            return contextRows
        }
        return tableView.selectedRowIndexes
    }
}

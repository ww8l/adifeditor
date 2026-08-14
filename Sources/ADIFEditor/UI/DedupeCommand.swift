import AppKit
import ADIFKit

/// Finding and removing duplicate QSOs.
///
/// Two sheets, in the order the operator thinks: which fields make two QSOs "the same",
/// then exactly which rows that turned out to mean. Nothing is deleted until the second
/// sheet is confirmed, and every row there can be unticked — the app proposes, the
/// operator decides (decision 12).
extension LogWindowController {

    private var dedupeDocument: LogDocument? { document as? LogDocument }

    /// What a POTA operator almost always means by a duplicate: same station, same day,
    /// same band, same mode. Checked when the log has them; a field the file does not
    /// carry is not offered at all.
    private static let defaultDedupeFields = ["QSO_DATE", "CALL", "BAND", "MODE"]

    // MARK: - Field picker

    @objc func findDuplicates(_ sender: Any?) {
        guard let document = dedupeDocument, let window else { return }

        let columns = document.log.columnNames
        guard !columns.isEmpty else {
            NSSound.beep()
            return
        }

        let checkboxes = columns.map { name -> NSButton in
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.state = Self.defaultDedupeFields.contains(name) ? .on : .off
            return box
        }

        let alert = NSAlert()
        alert.messageText = "Which fields make two QSOs the same?"
        alert.informativeText = "QSOs matching on every ticked field are duplicates. The "
                              + "first of each set is kept and you will see the rest "
                              + "before anything is deleted."
        alert.accessoryView = Self.scrollingStack(of: checkboxes, width: 260)
        alert.addButton(withTitle: "Find Duplicates")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let chosen = zip(columns, checkboxes)
                .filter { $0.1.state == .on }
                .map(\.0)

            DispatchQueue.main.async { self?.reviewDuplicates(matching: chosen) }
        }
    }

    // MARK: - Review

    private func reviewDuplicates(matching fields: [String]) {
        guard let document = dedupeDocument, let window else { return }

        guard !fields.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Tick at least one field."
            alert.informativeText = "With nothing to compare, every QSO would count as a "
                                  + "duplicate of the first one."
            alert.beginSheetModal(for: window)
            return
        }

        let groups = document.log.duplicateGroups(matching: fields)
        guard !groups.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No duplicates found."
            alert.informativeText = "No two QSOs match on \(fields.joined(separator: ", "))."
            alert.beginSheetModal(for: window)
            return
        }

        // One checkbox per row that would go, labelled with the values that matched and
        // the row it duplicates, so the operator can check the finding rather than trust
        // it. All ticked, because agreeing with the whole list is the common case.
        var rows: [Int] = []
        var checkboxes: [NSButton] = []

        for group in groups {
            for duplicate in group.duplicates {
                let box = NSButton(
                    checkboxWithTitle: Self.describe(row: duplicate,
                                                     sameAs: group.original,
                                                     fields: fields,
                                                     in: document.log),
                    target: nil,
                    action: nil)
                box.state = .on
                box.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                 weight: .regular)
                rows.append(duplicate)
                checkboxes.append(box)
            }
        }

        let total = rows.count
        let alert = NSAlert()
        alert.messageText = total == 1
            ? "1 duplicate QSO found."
            : "\(total) duplicate QSOs found."
        alert.informativeText = "Untick any you want to keep. The log on disk is not "
                              + "changed until you save."
        alert.accessoryView = Self.scrollingStack(of: checkboxes, width: 460)
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let doomed = zip(rows, checkboxes)
                .filter { $0.1.state == .on }
                .map(\.0)

            guard !doomed.isEmpty else { return }
            self?.dedupeDocument?.deleteRecords(at: IndexSet(doomed))
        }
    }

    /// `#12  W1ABC · 20260209 · 20m · FT8   — same as #3`
    private static func describe(row: Int,
                                 sameAs original: Int,
                                 fields: [String],
                                 in log: ADIFDocument) -> String {
        let values = fields
            .map { log.records[row][$0] ?? "" }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        // Row numbers are the grid's, which count from one.
        return "#\(row + 1)  \(values)   — same as #\(original + 1)"
    }

    // MARK: - Layout

    /// A column of controls that scrolls once it gets long. A log can carry thirty fields
    /// and a bad dedupe can propose hundreds of rows; neither should produce a sheet
    /// taller than the screen.
    private static func scrollingStack(of views: [NSView], width: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.layoutSubtreeIfNeeded()

        let contentHeight = stack.fittingSize.height
        let visibleHeight = min(contentHeight, 320)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0,
                                                    width: width, height: visibleHeight))
        scrollView.hasVerticalScroller = contentHeight > visibleHeight
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        stack.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.documentView = stack

        return scrollView
    }
}

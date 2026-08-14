import AppKit
import ADIFKit

/// The spreadsheet view of a log: one row per QSO, one column per field name found
/// anywhere in the file (§9).
///
/// Cells are editable; sort and row deletion are still to come. Nothing here writes to
/// disk — an edit changes the document in memory and marks it dirty, and the file is
/// untouched until Save (§6.1).
final class GridViewController: NSViewController {

    /// Unowned rather than weak: the document owns the window controller that owns this,
    /// so it outlives the grid by construction, and an optional here would put a `?` on
    /// every cell lookup for a case that cannot happen.
    private unowned let document: LogDocument

    private let tableView = NSTableView()

    /// Cached at init rather than read from the document per cell: `columnNames` walks
    /// every field of every record to compute the union, and `tableView` asks for column
    /// content thousands of times while scrolling.
    private let columns: [String]

    /// Identifier of the leading row-number column. Contains a space so it can never
    /// collide with an ADIF field name, which cannot have one.
    private static let rowNumberColumn = NSUserInterfaceItemIdentifier("row number")

    init(document: LogDocument) {
        self.document = document
        self.columns = document.log.columnNames
        super.init(nibName: nil, bundle: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordsDidChange(_:)),
            name: LogDocument.recordsDidChange,
            object: document
        )
    }

    required init?(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    /// Redraws a row the document says has changed — an edit, or an undo of one.
    /// Undo has to repaint the grid just as an edit does, and routing both through the
    /// document's notification is what stops that from being two code paths.
    @objc private func recordsDidChange(_ notification: Notification) {
        guard let row = notification.userInfo?[LogDocument.changedRowKey] as? Int,
              row < tableView.numberOfRows else {
            tableView.reloadData()
            return
        }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    // MARK: - View

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.documentView = tableView

        configureTableView()
        buildColumns()

        // A scroll view's fitting size is zero, and a window sizes itself to its content
        // view controller's fitting size — which is how this window kept coming up
        // clamped to its own minimum in a screen corner. These give it a size to find.
        // Low priority so they lose to the user dragging the window bigger or smaller.
        let width = scrollView.widthAnchor.constraint(equalToConstant: 1000)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 600)
        width.priority = .defaultLow
        height.priority = .defaultLow
        NSLayoutConstraint.activate([width, height])

        view = scrollView
    }

    private func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.rowHeight = 20
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        // Off until §9's rule is implemented — a user-reordered grid is supposed to
        // change the order fields are written in, and nothing does that yet. Letting
        // columns be dragged now would promise something the writer does not honor.
        tableView.allowsColumnReordering = false
    }

    // MARK: - Columns

    private func buildColumns() {
        let rowNumbers = NSTableColumn(identifier: Self.rowNumberColumn)
        rowNumbers.title = "#"
        rowNumbers.width = width(forRowNumbersUpTo: document.log.records.count)
        rowNumbers.resizingMask = .userResizingMask
        tableView.addTableColumn(rowNumbers)

        for name in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = width(forColumnNamed: name)
            column.minWidth = 40
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
    }

    /// Sizes a column to its widest cell, sampling rather than measuring every row: a
    /// 100k-QSO contest log would otherwise pay for a full pass before showing anything,
    /// and column widths are a starting point the user can drag anyway.
    private func width(forColumnNamed name: String) -> CGFloat {
        var widest = measure(name, font: Self.headerFont)
        for record in document.log.records.prefix(200) {
            guard let value = record[name], !value.isEmpty else { continue }
            widest = max(widest, measure(value, font: Self.cellFont))
        }
        return min(max(widest + Self.cellPadding, 44), 320)
    }

    private func width(forRowNumbersUpTo count: Int) -> CGFloat {
        measure(String(max(count, 1)), font: Self.cellFont) + Self.cellPadding
    }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    // MARK: - Appearance

    /// Monospaced digits, because a log is mostly dates, times, frequencies and signal
    /// reports, and proportional digits make columns of those hard to scan.
    private static let cellFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)
    private static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let cellPadding: CGFloat = 12
}

// MARK: - Data source

extension GridViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        document.log.records.count
    }
}

// MARK: - Delegate

extension GridViewController: NSTableViewDelegate {

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }

        let cell = reusableCell(for: tableColumn.identifier)
        let isRowNumber = tableColumn.identifier == Self.rowNumberColumn

        if isRowNumber {
            cell.textField?.stringValue = String(row + 1)
            cell.textField?.alignment = .right
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.isEditable = false
        } else {
            // An absent field and a present-but-empty one are both an empty cell here.
            // The distinction is real and the writer depends on it (decision 2), but it
            // is not something the grid can usefully show.
            cell.textField?.stringValue =
                document.log.records[row][tableColumn.identifier.rawValue] ?? ""
            cell.textField?.alignment = .left
            cell.textField?.textColor = .labelColor
            cell.textField?.isEditable = true
        }

        return cell
    }

    /// Commits an edit. Fires when the user presses Return or clicks away, which is
    /// AppKit's own definition of the edit being finished.
    ///
    /// The row and column are read back from the view rather than captured when the cell
    /// was built: cells are reused as the table scrolls, so a captured index goes stale
    /// the moment a row leaves the screen.
    @objc private func cellDidCommit(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        let column = tableView.column(for: sender)
        guard row >= 0, column >= 0 else { return }

        let identifier = tableView.tableColumns[column].identifier
        guard identifier != Self.rowNumberColumn else { return }

        document.setValue(sender.stringValue,
                          forColumn: identifier.rawValue,
                          inRecordAt: row)
    }

    private func reusableCell(for identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView {
            return existing
        }

        let text = NSTextField()
        text.font = Self.cellFont
        text.lineBreakMode = .byTruncatingTail
        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        text.usesSingleLineMode = true
        text.cell?.sendsActionOnEndEditing = true
        text.target = self
        text.action = #selector(cellDidCommit(_:))
        text.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.addSubview(text)
        cell.textField = text

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }
}

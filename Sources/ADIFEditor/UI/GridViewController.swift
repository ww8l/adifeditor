import AppKit
import ADIFKit

/// The spreadsheet view of a log: one row per QSO, one column per field name found
/// anywhere in the file (§9).
///
/// Read-only for now. Cell editing, sort, and row deletion are the next pieces of M1,
/// and each of them needs an undo story that this checkpoint deliberately does not have.
final class GridViewController: NSViewController {

    private let log: ADIFDocument
    private let tableView = NSTableView()

    /// Identifier of the leading row-number column. Prefixed so it can never collide
    /// with an ADIF field name, which cannot contain a space.
    private static let rowNumberColumn = NSUserInterfaceItemIdentifier("row number")

    init(log: ADIFDocument) {
        self.log = log
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not loaded from a nib")
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
        rowNumbers.width = width(forRowNumbersUpTo: log.records.count)
        rowNumbers.resizingMask = .userResizingMask
        tableView.addTableColumn(rowNumbers)

        for name in log.columnNames {
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
        for record in log.records.prefix(200) {
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
        log.records.count
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
        } else {
            // An absent field and a present-but-empty one are both an empty cell here.
            // The distinction is real and the writer depends on it (decision 2), but it
            // is not something the grid can usefully show.
            cell.textField?.stringValue = log.records[row][tableColumn.identifier.rawValue] ?? ""
            cell.textField?.alignment = .left
            cell.textField?.textColor = .labelColor
        }

        return cell
    }

    private func reusableCell(for identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView {
            return existing
        }

        let text = NSTextField(labelWithString: "")
        text.font = Self.cellFont
        text.lineBreakMode = .byTruncatingTail
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

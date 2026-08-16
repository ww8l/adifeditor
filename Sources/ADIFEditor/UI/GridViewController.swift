import AppKit
import ADIFKit

/// The spreadsheet view of a log: one row per QSO, one column per field name found
/// anywhere in the file (§9).
///
/// Cells are editable, headers sort, rows can be selected, cut, copied, pasted and
/// deleted. Nothing here writes to disk — a change marks the document dirty and the file
/// is untouched until Save (§6.1).
final class GridViewController: NSViewController {

    /// Unowned rather than weak: the document owns the window controller that owns this,
    /// so it outlives the grid by construction, and an optional here would put a `?` on
    /// every cell lookup for a case that cannot happen.
    unowned let document: LogDocument

    let tableView = NSTableView()

    /// Cached at init rather than read from the document per cell: `columnNames` walks
    /// every field of every record to compute the union, and `tableView` asks for column
    /// content thousands of times while scrolling.
    private var columns: [String]

    /// Identifier of the leading row-number column. Contains a space so it can never
    /// collide with an ADIF field name, which cannot have one.
    private static let rowNumberColumn = NSUserInterfaceItemIdentifier("row number")

    private lazy var findBar = FindBar()

    /// The current search's matches. Recomputed on every keystroke, and again after any
    /// edit — a record that no longer holds the text is no longer a match, and stepping
    /// onto a stale row index would select the wrong QSO.
    private var matches = FindMatches()

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
        addAnyNewColumns()

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

    /// Adds columns for field names the log has gained — pasted QSOs carrying a field
    /// nothing else in the file had. Without this their values would be in the document
    /// and saved to the file while being invisible in the grid.
    ///
    /// Only ever adds. A column whose every value has been deleted stays on screen for
    /// the rest of the session: having a column vanish because the last QSO using it was
    /// deleted would be a second surprise on top of the deletion, and the user may well
    /// be about to type a value back into it.
    private func addAnyNewColumns() {
        let newNames = document.log.columnNames.filter { !columns.contains($0) }
        guard !newNames.isEmpty else { return }

        for name in newNames {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = width(forColumnNamed: name)
            column.minWidth = 40
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
            tableView.addTableColumn(column)
        }

        columns.append(contentsOf: newNames)
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
        configureFindBar()

        // A scroll view has no intrinsic content size, so without these the grid's fitting
        // size is nothing and AppKit drives the window down to `minSize` — not when the
        // content view controller is assigned, but on the first layout pass afterwards,
        // which is why this looked like the window shrinking on its own. Low priority so
        // they break rather than fight the user dragging the window to any size they like.
        let size = computedContentSize
        let width = scrollView.widthAnchor.constraint(equalToConstant: size.width)
        let height = scrollView.heightAnchor.constraint(equalToConstant: size.height)
        width.priority = .defaultLow
        height.priority = .defaultLow
        NSLayoutConstraint.activate([width, height])

        // A stack view so hiding the find bar collapses it rather than leaving a gap:
        // `isHidden` on an arranged subview removes it from the layout, which is exactly
        // the behaviour wanted and is not worth hand-rolling with constraints.
        let stack = NSStackView(views: [findBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])

        view = stack
    }

    /// The content size a window showing this grid should open at.
    ///
    /// Asked for explicitly by `LogWindowController` rather than left to `fittingSize`.
    /// A scroll view has no fitting size of its own, and the low-priority width and height
    /// constraints that used to stand in for one did not survive: with no remembered frame
    /// to fall back on, the window came up clamped to its own `minSize` in a corner. A
    /// number this view computes is one that can be checked.
    ///
    /// Sized to the data — the columns this log actually has, the rows it actually holds —
    /// then held between a floor that is big enough to work in and a ceiling that keeps it
    /// on the screen. A 40-column contest log opens wide; a 12-column FT8 log does not
    /// open wider than it needs.
    var preferredWindowContentSize: NSSize {
        loadViewIfNeeded()
        return computedContentSize
    }

    /// The same calculation, without forcing the view to load — `loadView` itself needs
    /// this while it is still building the view it would otherwise be asked to load.
    private var computedContentSize: NSSize {
        let columnsWidth = tableView.tableColumns.reduce(CGFloat.zero) {
            $0 + $1.width + tableView.intercellSpacing.width
        }

        // The header is not laid out yet at the point this is asked for, so its height is
        // a constant rather than a measurement.
        let headerHeight: CGFloat = 28
        let rowsHeight = CGFloat(tableView.numberOfRows)
                       * (tableView.rowHeight + tableView.intercellSpacing.height)

        // `visibleFrame` excludes the menu bar and the Dock, so a window this size is one
        // the user can actually see all of.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)

        return NSSize(
            width: min(max(columnsWidth + 4, 760), screen.width * 0.9),
            height: min(max(rowsHeight + headerHeight + 4, 420), screen.height * 0.85)
        )
    }

    // MARK: - Find

    private func configureFindBar() {
        findBar.isHidden = true

        findBar.onSearch = { [weak self] in self?.search(for: $0) }
        findBar.onNext = { [weak self] in self?.step { $0.next(after: $1) } }
        findBar.onPrevious = { [weak self] in self?.step { $0.previous(before: $1) } }
        findBar.onClose = { [weak self] in self?.closeFind() }
    }

    /// ⌘F. Opens the bar if it is closed and focuses it either way, so a second ⌘F is a
    /// new search rather than a no-op.
    @objc func showFind(_ sender: Any?) {
        findBar.isHidden = false
        findBar.takeFocus()
    }

    @objc func findNext(_ sender: Any?) {
        step { $0.next(after: $1) }
    }

    @objc func findPrevious(_ sender: Any?) {
        step { $0.previous(before: $1) }
    }

    private func closeFind() {
        findBar.isHidden = true
        view.window?.makeFirstResponder(tableView)
    }

    /// Runs the search and moves to the first match at or after where the operator is,
    /// rather than jumping to the top of the log every keystroke.
    private func search(for text: String) {
        matches = document.log.find(text)

        guard !text.isEmpty else {
            findBar.showStatus(position: nil, of: nil)
            return
        }
        guard !matches.isEmpty else {
            findBar.showStatus(position: 0, of: 0)
            return
        }

        // `previous(before:)` of the row after the selection, so a selected row that
        // itself matches stays put while the text is being typed. Stepping is what moves
        // off a match; typing should not.
        let anchor = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        let target = anchor.flatMap { matches.ordinal(of: $0) != nil ? $0 : nil }
            ?? matches.next(after: anchor.map { $0 - 1 })

        select(match: target)
    }

    private func step(_ move: (FindMatches, Int?) -> Int?) {
        // Recomputed rather than trusted: rows may have been edited, sorted or deleted
        // since the text was typed, and a stale index would select an unrelated QSO.
        matches = document.log.find(findBar.searchText)
        select(match: move(matches, tableView.selectedRow >= 0 ? tableView.selectedRow : nil))
    }

    private func select(match row: Int?) {
        guard let row, row < tableView.numberOfRows else {
            findBar.showStatus(position: matches.isEmpty ? 0 : nil, of: matches.count)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        findBar.showStatus(position: matches.ordinal(of: row), of: matches.count)
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

        tableView.menu = rowMenu
    }

    // MARK: - Context menu

    lazy var rowMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self

        // Enablement is decided in `menuNeedsUpdate`, where the target rows are known.
        // Left on, AppKit's automatic validation would overrule that.
        menu.autoenablesItems = false

        for (title, action) in [
            ("Cut", #selector(cut(_:))),
            ("Copy", #selector(copy(_:))),
            ("Paste", #selector(paste(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete",
                                action: #selector(deleteClickedRows(_:)),
                                keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)

        return menu
    }()

    /// The rows the context menu will act on, captured while the menu is being built.
    ///
    /// Captured rather than read at click time because `clickedRow` is only meaningful
    /// during the click that opened the menu, and the action fires later.
    private(set) var contextRows = IndexSet()

    @objc private func deleteClickedRows(_ sender: Any?) {
        guard !contextRows.isEmpty else { return }
        document.deleteRecords(at: contextRows)
        tableView.deselectAll(nil)
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

            // Clicking the header sorts (§10.1). The row-number column deliberately gets
            // no prototype — it numbers positions, so sorting by it is meaningless.
            column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)

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

    /// Header clicks arrive here. The sort is done by the document rather than the view
    /// because it reorders the records themselves, which is an undoable edit — the grid
    /// is not keeping a separately ordered view of an unchanged log.
    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let column = descriptor.key else { return }

        document.sortRecords(byColumn: column, ascending: descriptor.ascending)
    }
}

// MARK: - Context menu

extension GridViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = tableView.clickedRow
        let selection = tableView.selectedRowIndexes

        if clicked < 0 {
            // Right-click below the last row: nothing was aimed at, so fall back to
            // whatever is selected.
            contextRows = selection
        } else if selection.contains(clicked) {
            contextRows = selection
        } else {
            // Right-clicking outside the selection targets that row alone, and takes the
            // selection with it so the highlight matches what Delete is about to remove.
            contextRows = IndexSet(integer: clicked)
            tableView.selectRowIndexes(contextRows, byExtendingSelection: false)
        }

        let hasRows = !contextRows.isEmpty
        let count = contextRows.count
        let noun = count == 1 ? "QSO" : "\(count) QSOs"

        for item in menu.items {
            switch item.action {
            case #selector(cut(_:)):
                item.isEnabled = hasRows
                item.title = hasRows ? "Cut \(noun)" : "Cut"
            case #selector(copy(_:)):
                item.isEnabled = hasRows
                item.title = hasRows ? "Copy \(noun)" : "Copy"
            case #selector(paste(_:)):
                item.isEnabled = Self.pasteboardLooksLikeADIF
            case #selector(deleteClickedRows(_:)):
                item.isEnabled = hasRows
                item.title = hasRows ? "Delete \(noun)" : "Delete"
            default:
                break
            }
        }
    }
}

// MARK: - Menu validation

extension GridViewController: NSMenuItemValidation {

    /// Greys out Delete when nothing is selected rather than letting it fire and do
    /// nothing. `NSViewController` has no `validateMenuItem` of its own to override —
    /// the responder chain finds it through this protocol.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)), #selector(cut(_:)), #selector(copy(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return Self.pasteboardLooksLikeADIF
        default:
            return true
        }
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

    /// Deletes the selected QSOs. Reached from Edit ▸ Delete and from the Delete key,
    /// both of which route `delete:` down the responder chain to here.
    @objc func delete(_ sender: Any?) {
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return }

        document.deleteRecords(at: selection)
        tableView.deselectAll(nil)
    }

    /// The Delete key. `NSTableView` does not turn it into `delete:` on its own.
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]      // Delete and Forward Delete
        if deleteKeys.contains(event.keyCode), !tableView.selectedRowIndexes.isEmpty {
            delete(nil)
            return
        }
        super.keyDown(with: event)
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

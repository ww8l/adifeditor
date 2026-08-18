import AppKit
import ADIFKit
import QRZKit

/// Filling station details from QRZ (§10.4).
///
/// The same shape as dedupe, for the same reason: the app proposes and the operator
/// decides (decision 12). Choose what to fill, watch it run, then look at every cell it
/// wants to write before any of them is written. Nothing reaches the grid until the
/// review sheet is confirmed, and nothing reaches disk until Save (§6.1).
///
/// This is the only command in the app that opens a connection, and it does so only when
/// invoked. With no credentials stored it does not get as far as trying.
extension LogWindowController {

    private var qrzDocument: LogDocument? { document as? LogDocument }

    private var grid: GridViewController? { contentViewController as? GridViewController }

    // MARK: - Entry

    @objc func fillFromQRZ(_ sender: Any?) {
        // Especially here: `proposedFills` reads a cell the user has just typed into as
        // still empty, and would offer to fill over the top of it.
        guard commitPendingEdit() else { return }
        guard let document = qrzDocument, let window else { return }

        let credentials: QRZCredentials
        do {
            guard let stored = try Preferences.credentials() else {
                offerToConfigureQRZ()
                return
            }
            credentials = stored
        } catch {
            // The Keychain refused. Saying so is the point: the alert below would send
            // the user to Settings to retype a password that is already there.
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }

        // No selection means the whole log. Said out loud in the next sheet rather than
        // assumed — looking up 400 QSOs because nothing happened to be selected is the
        // kind of surprise that costs an API quota.
        let selected = grid?.tableView.selectedRowIndexes ?? IndexSet()
        let rows = selected.isEmpty ? IndexSet(document.log.records.indices) : selected

        let callsigns = QRZLookup.callsigns(in: document.log, rows: rows)
        guard !callsigns.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to look up."
            alert.informativeText = selected.isEmpty
                ? "This log has no callsigns in its CALL column."
                : "None of the selected rows has a callsign."
            alert.beginSheetModal(for: window)
            return
        }

        chooseFields(callsigns: callsigns,
                     rows: rows,
                     credentials: credentials,
                     wholeLog: selected.isEmpty)
    }

    /// Credentials are Preferences' business, so this points there rather than growing a
    /// second place to type them.
    private func offerToConfigureQRZ() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "No QRZ credentials have been entered."
        alert.informativeText = "The lookup needs a QRZ XML subscription. Enter the "
                              + "username and password in Settings and they will be kept "
                              + "in your Keychain."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async {
                PreferencesWindowController.shared.showWindow(nil)
            }
        }
    }

    // MARK: - What to fill

    private func chooseFields(callsigns: [String],
                              rows: IndexSet,
                              credentials: QRZCredentials,
                              wholeLog: Bool) {
        guard let window else { return }

        let remembered = Preferences.qrzFields
        let checkboxes = QRZFieldMapping.fields.map { field -> NSButton in
            let box = NSButton(checkboxWithTitle: field, target: nil, action: nil)
            box.state = remembered.contains(field) ? .on : .off
            return box
        }

        let alert = NSAlert()
        alert.messageText = callsigns.count == 1
            ? "Look up 1 callsign at QRZ?"
            : "Look up \(callsigns.count) callsigns at QRZ?"
        alert.informativeText = (wholeLog
            ? "Nothing is selected, so this covers the whole log. "
            : "")
            + "Only empty cells are filled — anything you have already typed is left "
            + "alone. You will see every proposed value before it is written."
        alert.accessoryView = SheetLayout.scrollingStack(of: checkboxes, width: 260)
        alert.addButton(withTitle: "Look Up")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let chosen = Set(zip(QRZFieldMapping.fields, checkboxes)
                .filter { $0.1.state == .on }
                .map(\.0))

            guard !chosen.isEmpty else { NSSound.beep(); return }
            Preferences.qrzFields = chosen

            DispatchQueue.main.async {
                self?.runLookup(callsigns: callsigns,
                                rows: rows,
                                fields: chosen,
                                credentials: credentials)
            }
        }
    }

    // MARK: - Running

    private func runLookup(callsigns: [String],
                           rows: IndexSet,
                           fields: Set<String>,
                           credentials: QRZCredentials) {
        guard let window else { return }

        let session = QRZSession(credentials: credentials, transport: URLSessionTransport())
        let sheet = QRZProgressSheet(total: callsigns.count)
        sheet.present(in: window)

        let task = Task { @MainActor [weak self] in
            let result = await QRZBatch.lookUp(callsigns, using: session) { completed, total in
                Task { @MainActor in sheet.update(completed: completed, total: total) }
            }

            sheet.dismiss()

            // Out of the sheet's dismissal before presenting another: AppKit will not
            // put up a sheet while the previous one is still going away.
            DispatchQueue.main.async {
                self?.review(result: result, rows: rows, fields: fields)
            }
        }

        sheet.onCancel = { task.cancel() }
    }

    // MARK: - Review

    private func review(result: QRZBatchResult, rows: IndexSet, fields: Set<String>) {
        guard let document = qrzDocument, let window else { return }

        let fills = QRZLookup.proposedFills(in: document.log,
                                            rows: rows,
                                            results: result.found,
                                            fields: fields)

        guard !fills.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to fill."
            alert.informativeText = Self.outcome(result)
                + (result.found.isEmpty
                    ? ""
                    : " Every field QRZ returned is already filled in this log.")
            alert.beginSheetModal(for: window)
            return
        }

        // One checkbox per cell, all ticked. Labelled with the row number the grid shows,
        // the callsign, the field, and the value — enough for the operator to disagree
        // with any single one without having to trust the batch as a whole.
        let checkboxes = fills.map { fill -> NSButton in
            let box = NSButton(checkboxWithTitle: Self.describe(fill, in: document.log),
                               target: nil, action: nil)
            box.state = .on
            box.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                             weight: .regular)
            return box
        }

        let alert = NSAlert()
        alert.messageText = fills.count == 1
            ? "Fill 1 cell from QRZ?"
            : "Fill \(fills.count) cells from QRZ?"
        alert.informativeText = Self.outcome(result)
            + " Untick anything you would rather keep empty. "
            + "The log on disk is not changed until you save."
        alert.accessoryView = SheetLayout.scrollingStack(of: checkboxes, width: 520)
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let chosen = zip(fills, checkboxes)
                .filter { $0.1.state == .on }
                .map(\.0)

            guard !chosen.isEmpty, let document = self?.qrzDocument else { return }

            // One undoable edit for the whole batch (§10.4): a lookup either fills what
            // the operator confirmed or does nothing, and one Undo puts it all back.
            // Filling cells does not move a row, so an order a sort put the log in still
            // holds afterwards.
            document.replaceAllRecords(
                QRZLookup.records(in: document.log, applying: chosen),
                actionName: "Fill from QRZ",
                sortedBy: document.sortedBy)
        }
    }

    /// `#12  W1ABC   GRIDSQUARE → FN32aa`
    private static func describe(_ fill: ProposedFill, in log: ADIFDocument) -> String {
        let callsign = log.records.indices.contains(fill.row)
            ? (log.records[fill.row]["CALL"] ?? "")
            : ""

        // Row numbers are the grid's, which count from one.
        return "#\(fill.row + 1)  \(callsign)   \(fill.field) → \(fill.value)"
    }

    /// A sentence about what the batch managed, shown on both review paths.
    ///
    /// Every failure is named. §10.4 asks for a diagnostic saying which callsigns could
    /// not be looked up and why, and burying that under a successful-looking sheet would
    /// be the same as not saying it.
    private static func outcome(_ result: QRZBatchResult) -> String {
        var parts: [String] = []

        if let stopped = result.stoppedEarly {
            let skipped = result.notAttempted.count
            parts.append("The lookup stopped after \(result.found.count) "
                       + "\(result.found.count == 1 ? "callsign" : "callsigns"): "
                       + (stopped.errorDescription ?? "\(stopped)")
                       + (skipped > 0
                            ? " \(skipped) \(skipped == 1 ? "callsign was" : "callsigns were") "
                              + "not tried."
                            : ""))
        } else if result.wasCancelled {
            parts.append("Cancelled after \(result.found.count) of "
                       + "\(result.found.count + result.notAttempted.count) callsigns.")
        }

        let notFound = result.failures.filter {
            if case .callsignNotFound = $0.error { return true }
            return false
        }
        if !notFound.isEmpty {
            let names = notFound.map(\.callsign).joined(separator: ", ")
            parts.append("QRZ has no record of \(names).")
        }

        let others = result.failures.filter {
            if case .callsignNotFound = $0.error { return false }
            return true
        }
        for failure in others {
            parts.append("\(failure.callsign): "
                       + (failure.error.errorDescription ?? "\(failure.error)"))
        }

        return parts.joined(separator: " ")
    }
}

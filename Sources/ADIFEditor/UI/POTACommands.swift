import AppKit
import ADIFKit
import POTAKit

/// The two POTA commands (§10.2), as the operator meets them.
///
/// Stamp and Split are one command with a fork in it: type one park reference and the log
/// is stamped in place, type several and it becomes a split. The spec puts that fork in
/// the interface rather than in two separate prompts, so the operator does not have to
/// know in advance which one they wanted.
extension LogWindowController {

    private var logDocument: LogDocument? { document as? LogDocument }

    /// Whether to also write `MY_SIG` = `POTA`. Off by default (§10.2), and since
    /// Preferences arrived with the QRZ lookup it finally has a checkbox rather than
    /// being reachable only by setting the default by hand.
    private var writesProgramField: Bool {
        Preferences.writeMySigField
    }

    // MARK: - Commands

    /// The whole POTA feature, on one button.
    ///
    /// §10.2 specified two commands and decision 15 made them one code path; this is the
    /// interface catching up (decision 16). Two buttons that behave identically and differ
    /// only in how many references you happen to type is a choice the operator should not
    /// have to make — the number of parks already says which one they meant.
    @objc func stampForPOTA(_ sender: Any?) {
        promptForParks(
            message: "Stamp a park reference",
            information: "Writes a new file with this reference on every QSO that does not "
                       + "already have one. Enter more than one reference, separated by "
                       + "commas, and you get a file per park, each holding every QSO — "
                       + "being inside three parks means each contact counts for all "
                       + "three. The log you have open is not changed either way.",
            confirmTitle: "Continue"
        ) { [weak self] parks in
            self?.apply(parks)
        }
    }

    /// One park or many, the path is the same: choose a destination, confirm the names,
    /// write new files.
    ///
    /// §10.2 originally stamped a single park into the open document in memory and only
    /// wrote files for a split. The owner asked for one workflow, and it is the better
    /// one: a stamp's whole purpose is producing the file to upload, under POTA's name
    /// for it, and writing a new file means the log that came off the radio is never
    /// touched at all (§6.1) rather than merely not-yet-saved. §10.2 is amended
    /// (decision 15).
    private func apply(_ parks: [ParkReference]) {
        askAboutExistingReferences(parks)
    }

    // MARK: - Split

    /// §6.3's required question, asked only when there is something to overwrite.
    private func askAboutExistingReferences(_ parks: [ParkReference]) {
        guard let document = logDocument, let window else { return }

        let existing = POTAStamp.recordsWithExistingReference(in: document.log)
        guard existing > 0 else {
            chooseDestination(for: parks, replacingExisting: false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(existing) rows already have park references. Replace them in "
                          + "the output?"
        alert.informativeText = "The log you have open is not changed either way."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Existing")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.chooseDestination(for: parks, replacingExisting: true)
            case .alertSecondButtonReturn:
                self?.chooseDestination(for: parks, replacingExisting: false)
            default:
                break
            }
        }
    }

    private func chooseDestination(for parks: [ParkReference], replacingExisting: Bool) {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = parks.count == 1
            ? "Where should the stamped log go?"
            : "Where should the \(parks.count) park files go?"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            // Out of the panel's completion before putting up another sheet: AppKit will
            // not present one while the previous is still going away.
            DispatchQueue.main.async {
                self?.confirmFilenames(for: parks, in: folder, replacingExisting: replacingExisting)
            }
        }
    }

    /// The app proposes the filenames and the operator confirms or edits them (§10.2).
    private func confirmFilenames(for parks: [ParkReference],
                                  in folder: URL,
                                  replacingExisting: Bool) {
        guard let document = logDocument, let window else { return }

        let callsign = POTAFilename.callsign(in: document.log) ?? ""
        let date = POTAFilename.earliestDate(in: document.log)

        let fields = parks.map { park -> NSTextField in
            let field = NSTextField(string: POTAFilename.name(callsign: callsign,
                                                              park: park,
                                                              date: date))
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            return field
        }

        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360,
                             height: CGFloat(parks.count) * 30)
        for field in fields {
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }

        let alert = NSAlert()
        alert.messageText = parks.count == 1
            ? "Write this file to \(folder.lastPathComponent)?"
            : "Write \(parks.count) files to \(folder.lastPathComponent)?"

        if callsign.isEmpty {
            // §10.2 says to prompt once when the log carries no callsign. The name is
            // editable anyway, so the prompt is the name itself with the callsign missing
            // rather than another sheet in front of this one.
            alert.informativeText = "This log has no STATION_CALLSIGN or OPERATOR, so the "
                                  + "callsign is missing from the name below. Add it here."
        } else {
            alert.informativeText = parks.count == 1
                ? "Every QSO without a park reference gets \(parks[0].text)."
                : "Each file holds every QSO, differing only in the park reference."
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Write")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let names = fields.map(\.stringValue)
            DispatchQueue.main.async {
                self?.writeSplit(parks: parks,
                                 names: names,
                                 folder: folder,
                                 replacingExisting: replacingExisting)
            }
        }
    }

    private func writeSplit(parks: [ParkReference],
                            names: [String],
                            folder: URL,
                            replacingExisting: Bool) {
        guard let document = logDocument, let window else { return }

        let outputs = POTAStamp.split(document.log,
                                      into: parks,
                                      replacingExistingReferences: replacingExisting,
                                      alsoWriteProgramField: writesProgramField)

        // Never quietly over an existing file. These are activation logs, and a name
        // collision most likely means a previous run of this same split.
        let targets = zip(outputs, names).map { folder.appendingPathComponent($1) }
        let clashes = targets.filter { FileManager.default.fileExists(atPath: $0.path) }

        if !clashes.isEmpty {
            let alert = NSAlert()
            alert.messageText = clashes.count == 1
                ? "\(clashes[0].lastPathComponent) already exists."
                : "\(clashes.count) of these files already exist."
            alert.informativeText = "Replace them?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.write(outputs: outputs, to: targets)
            }
            return
        }

        write(outputs: outputs, to: targets)
    }

    private func write(outputs: [(park: ParkReference, document: ADIFDocument)],
                       to targets: [URL]) {
        guard let window else { return }

        do {
            for (output, target) in zip(outputs, targets) {
                try ADIFWriter.write(output.document).write(to: target, options: .atomic)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window)
            return
        }

        // Reveal rather than announce: the operator's next step is to upload these, and
        // the Finder is where they do it from.
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    // MARK: - Prompt

    private func promptForParks(message: String,
                                information: String,
                                confirmTitle: String,
                                then handle: @escaping ([ParkReference]) -> Void) {
        guard let window else { return }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "US-1234"

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let parks = ParkReference.list(from: field.stringValue)
            guard !parks.isEmpty else { NSSound.beep(); return }

            // Lenient (§10.2): a reference that does not match POTA's shape is queried,
            // never refused. POTA's scheme has changed before.
            let odd = parks.filter { !$0.isWellFormed }
            guard !odd.isEmpty else {
                DispatchQueue.main.async { handle(parks) }
                return
            }

            DispatchQueue.main.async {
                self?.confirmOddReferences(odd, all: parks, then: handle)
            }
        }
    }

    private func confirmOddReferences(_ odd: [ParkReference],
                                      all: [ParkReference],
                                      then handle: @escaping ([ParkReference]) -> Void) {
        guard let window else { return }

        let list = odd.map(\.text).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = odd.count == 1
            ? "\(list) does not look like a park reference."
            : "These do not look like park references: \(list)"
        alert.informativeText = "POTA references are usually like US-1234. Use it anyway?"
        alert.addButton(withTitle: "Use It")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { handle(all) }
        }
    }
}

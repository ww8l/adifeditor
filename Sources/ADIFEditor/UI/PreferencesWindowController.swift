import AppKit

/// The Preferences window.
///
/// M4's item, pulled forward because the QRZ credentials need somewhere to live (§10.4).
/// `MY_SIG` gets a home here at the same time — it has been reachable only by setting a
/// default by hand since M1.
///
/// One window, shared: `shared` keeps the same controller across openings so Command-comma
/// brings back the one you were looking at rather than stacking new ones.
final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let mySigCheckbox = NSButton(checkboxWithTitle: "Also write MY_SIG = POTA",
                                         target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        super.init(window: window)

        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        usernameField.placeholderString = "QRZ username"
        passwordField.placeholderString = "QRZ password"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveQRZ(_:)))
        saveButton.keyEquivalent = "\r"

        removeButton.target = self
        removeButton.action = #selector(removeQRZ(_:))

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        mySigCheckbox.target = self
        mySigCheckbox.action = #selector(toggleMySig(_:))

        let buttons = NSStackView(views: [saveButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let content = NSStackView(views: [
            heading("QRZ Callsign Lookup"),
            explanation(
                "Needs a QRZ XML subscription — the lookup is theirs, not the app's, and "
                + "it is billed by them. With no credentials here the app makes no network "
                + "connections at all, and every other feature works unchanged."),
            labelled("Username", usernameField),
            labelled("Password", passwordField),
            buttons,
            statusLabel,
            separator(),
            heading("POTA"),
            mySigCheckbox,
            explanation(
                "Off by default. POTA does not require MY_SIG, and the park reference in "
                + "MY_SIG_INFO is what the upload reads.")
        ])

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        container.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            usernameField.widthAnchor.constraint(equalToConstant: 260),
            passwordField.widthAnchor.constraint(equalToConstant: 260),
            statusLabel.widthAnchor.constraint(equalToConstant: 400)
        ])

        return container
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func explanation(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return label
    }

    private func labelled(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return line
    }

    // MARK: - State

    private func reload() {
        usernameField.stringValue = Preferences.qrzUsername
        mySigCheckbox.state = Preferences.writeMySigField ? .on : .off

        // The stored password is never put back into the field. Reading it out of the
        // Keychain to display it would put it on screen and in the view hierarchy for no
        // benefit — the user does not need to see it to know it is there.
        passwordField.stringValue = ""

        let configured = Preferences.hasQRZCredentials
        removeButton.isEnabled = configured
        statusLabel.stringValue = configured
            ? "A password is stored in your Keychain for \(Preferences.qrzUsername)."
            : "No credentials stored. The lookup is unavailable and the app stays offline."
    }

    // MARK: - Actions

    @objc private func saveQRZ(_ sender: Any?) {
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue

        guard !username.isEmpty, !password.isEmpty else {
            statusLabel.stringValue = "Enter both a username and a password."
            return
        }

        do {
            try Preferences.setQRZCredentials(username: username, password: password)
            passwordField.stringValue = ""
            reload()
            statusLabel.stringValue = "Stored in your Keychain. "
                                    + "The app will use it when you run Fill from QRZ."
        } catch {
            // No fallback: if the Keychain refused, nothing was stored, and saying so is
            // the whole of the response (§6.5 — credentials live there or nowhere).
            presentInWindow(error)
            reload()
        }
    }

    @objc private func removeQRZ(_ sender: Any?) {
        do {
            try Preferences.clearQRZCredentials()
            passwordField.stringValue = ""
            reload()
            statusLabel.stringValue = "Removed. The app is offline again."
        } catch {
            presentInWindow(error)
        }
    }

    @objc private func toggleMySig(_ sender: Any?) {
        Preferences.writeMySigField = mySigCheckbox.state == .on
    }

    private func presentInWindow(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}

import AppKit

/// The find strip above the grid, shown by ⌘F and dismissed by Escape.
///
/// Hidden until asked for, unlike a filter bar, because find leaves the grid alone: there
/// is no state here that changes what the operator is looking at once the bar is gone.
final class FindBar: NSView {

    var onSearch: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?

    static let height: CGFloat = 32

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let replaceField = NSTextField()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    var searchText: String { field.stringValue }
    var replacementText: String { replaceField.stringValue }

    /// ⌥⌘F. Same bar, with the keyboard in the replace field.
    func takeReplaceFocus() {
        window?.makeFirstResponder(replaceField)
        replaceField.currentEditor()?.selectAll(nil)
    }

    /// A one-off report after a replace, such as "Replaced in 7 QSOs". Cleared by the
    /// next search or step, which report their own counts.
    func showMessage(_ message: String) {
        status.stringValue = message
        status.textColor = .secondaryLabelColor
    }

    /// Moves the keyboard to the find field and selects what is there, so a second ⌘F
    /// replaces the previous search rather than appending to it.
    func takeFocus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// `nil` matches means nothing has been typed yet — no count, rather than "0 of 0".
    func showStatus(position: Int?, of total: Int?) {
        guard let total else {
            status.stringValue = ""
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            replaceButton.isEnabled = false
            replaceAllButton.isEnabled = false
            return
        }

        if total == 0 {
            status.stringValue = "Not found"
            status.textColor = .systemOrange
        } else {
            status.stringValue = position.map { "\($0) of \(total)" } ?? "\(total) found"
            status.textColor = .secondaryLabelColor
        }

        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
        replaceButton.isEnabled = total > 0
        replaceAllButton.isEnabled = total > 0
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = "Find in log"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchChanged)
        field.delegate = self

        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        configure(previousButton, symbol: "chevron.left",
                  tooltip: "Previous match", action: #selector(goPrevious))
        configure(nextButton, symbol: "chevron.right",
                  tooltip: "Next match", action: #selector(goNext))

        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.controlSize = .small
        replaceField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replaceField.placeholderString = "Replace with"
        replaceField.delegate = self

        configure(replaceButton, title: "Replace",
                  tooltip: "Replace in the selected QSOs, then find the next match",
                  action: #selector(replace))
        configure(replaceAllButton, title: "All",
                  tooltip: "Replace in every QSO that matches",
                  action: #selector(replaceAll))

        let done = NSButton()
        done.translatesAutoresizingMaskIntoConstraints = false
        done.title = "Done"
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        done.target = self
        done.action = #selector(close)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        for view in [field, replaceField, replaceButton, replaceAllButton,
                     status, previousButton, nextButton, done, separator] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),

            replaceField.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            replaceField.centerYAnchor.constraint(equalTo: centerYAnchor),
            replaceField.widthAnchor.constraint(equalToConstant: 160),

            replaceButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor,
                                                   constant: 6),
            replaceButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            replaceAllButton.leadingAnchor.constraint(equalTo: replaceButton.trailingAnchor,
                                                      constant: 4),
            replaceAllButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            status.leadingAnchor.constraint(equalTo: replaceAllButton.trailingAnchor,
                                            constant: 10),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),

            previousButton.leadingAnchor.constraint(greaterThanOrEqualTo:
                                                        status.trailingAnchor, constant: 10),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor,
                                                constant: 4),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            done.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 10),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        showStatus(position: nil, of: nil)
    }

    private func configure(_ button: NSButton, symbol: String,
                           tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    private func configure(_ button: NSButton, title: String,
                           tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    // MARK: - Actions

    @objc private func searchChanged() { onSearch?(field.stringValue) }
    @objc private func goNext() { onNext?() }
    @objc private func goPrevious() { onPrevious?() }
    @objc private func close() { onClose?() }
    @objc private func replace() { onReplace?() }
    @objc private func replaceAll() { onReplaceAll?() }
}

extension FindBar: NSSearchFieldDelegate {

    /// Return steps to the next match — or, in the replace field, replaces and then steps —
    /// and Escape closes the bar. Both arrive here rather than as key events, because
    /// while a field is first responder the field editor has them first.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField { onReplace?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

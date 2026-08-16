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

    static let height: CGFloat = 32

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    var searchText: String { field.stringValue }

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

        for view in [field, status, previousButton, nextButton, done, separator] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),

            status.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
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

    // MARK: - Actions

    @objc private func searchChanged() { onSearch?(field.stringValue) }
    @objc private func goNext() { onNext?() }
    @objc private func goPrevious() { onPrevious?() }
    @objc private func close() { onClose?() }
}

extension FindBar: NSSearchFieldDelegate {

    /// Return steps to the next match and Escape closes the bar. Both arrive here rather
    /// than as key events, because while the field is first responder the field editor has
    /// them first.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onNext?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

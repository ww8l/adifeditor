import AppKit

/// A sheet that says what the lookup is doing and lets the operator stop it.
///
/// The only place in the app where the user waits on something outside the machine, so it
/// is also the only place that needs a progress bar and a Cancel button. Cancelling keeps
/// whatever came back already (`QRZBatch` returns partial results), so stopping a long
/// batch costs the operator nothing they had earned.
@MainActor
final class QRZProgressSheet {

    private let sheetWindow: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    /// Called when the operator presses Cancel.
    var onCancel: (() -> Void)?

    init(total: Int) {
        sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(total, 1))
        bar.doubleValue = 0
        bar.style = .bar
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), cancel])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [label, bar, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 320)
        ])

        sheetWindow.contentView = container
        update(completed: 0, total: total)
    }

    func present(in parent: NSWindow) {
        parent.beginSheet(sheetWindow)
    }

    func update(completed: Int, total: Int) {
        bar.maxValue = Double(max(total, 1))
        bar.doubleValue = Double(completed)
        label.stringValue = "Looking up \(completed + 1) of \(total) at QRZ…"

        if completed >= total {
            label.stringValue = "Finishing…"
        }
    }

    func dismiss() {
        sheetWindow.sheetParent?.endSheet(sheetWindow)
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel?()
    }
}

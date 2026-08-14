import AppKit
import ADIFKit

/// The window around a log: the grid, and — when the parser had to recover from
/// something — a banner under the title bar saying what.
final class LogWindowController: NSWindowController {

    /// Shared across log windows on purpose: resize one to suit your screen and the
    /// next log you open comes up the same size.
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("LogWindow")

    /// Whether this window opened at a size and place the user had chosen before.
    private let hasSavedFrame: Bool

    /// `showWindow` runs again every time the document is brought forward; placement
    /// should not.
    private var hasBeenPlaced = false

    init(document: LogDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 240)

        // The window takes its size from the grid's fitting size, which the grid supplies
        // deliberately (see `GridViewController.loadView`) — a scroll view has none of
        // its own, and a window with a zero-sized content view clamps itself to
        // `minSize` in a screen corner.
        window.contentViewController = GridViewController(document: document)

        // Order matters: `setFrameUsingName` restores a size the user chose earlier and
        // reports whether it found one, while `setFrameAutosaveName` both registers the
        // window for saving *and* restores, so it has to come second.
        let restoredSavedFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        self.hasSavedFrame = restoredSavedFrame
        super.init(window: window)

        installToolbar()

        if !document.warnings.isEmpty {
            addWarningBanner(text: ParseWarningText.summary(document.warnings))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    /// Not `windowDidLoad`: that is a nib-loading callback and never fires for a window
    /// built in code, so placement has to happen here.
    ///
    /// A window with no remembered frame is centered, and centered this late because the
    /// grid's final width is not settled until the view has laid out. Once the user has
    /// sized a window themselves, that frame is restored instead and further windows
    /// cascade off it rather than landing on top of each other.
    override func showWindow(_ sender: Any?) {
        shouldCascadeWindows = hasSavedFrame

        if !hasSavedFrame && !hasBeenPlaced {
            hasBeenPlaced = true
            window?.layoutIfNeeded()
            window?.center()
        }

        super.showWindow(sender)
    }

    // MARK: - Toolbar

    /// §10.2 asks for the POTA command on a visible toolbar button as well as in a menu,
    /// since it is the reason the app exists.
    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "LogToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar
    }

    /// The file opened, so this is advisory rather than an alert to dismiss (§6.4). A
    /// titlebar accessory keeps it visible without stealing a click or displacing the
    /// grid's own layout.
    private func addWarningBanner(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: "Warning")
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        let banner = NSView()
        banner.addSubview(icon)
        banner.addSubview(label)

        NSLayoutConstraint.activate([
            banner.heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: banner.trailingAnchor,
                                            constant: -12),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = banner
        accessory.layoutAttribute = .bottom
        window?.addTitlebarAccessoryViewController(accessory)
    }
}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    static let pota = NSToolbarItem.Identifier("POTA")
}

extension LogWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pota, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pota, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .pota:
            return toolbarItem(identifier,
                               label: "POTA",
                               symbol: "mappin.and.ellipse",
                               tooltip: "Write a log stamped with a park reference, "
                                      + "or one file per park for an n-fer",
                               action: #selector(stampForPOTA(_:)))
        default:
            return nil
        }
    }

    private func toolbarItem(_ identifier: NSToolbarItem.Identifier,
                             label: String,
                             symbol: String,
                             tooltip: String,
                             action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}

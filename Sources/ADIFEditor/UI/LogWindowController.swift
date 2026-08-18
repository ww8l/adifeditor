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

    /// The frame this window is meant to open at, captured while it is still correct.
    ///
    /// Needed because AppKit re-derives the window's size from its content view
    /// controller on the first layout pass, after `init` has finished and before
    /// `showWindow` runs. The grid now supplies a fitting size, so that pass should agree
    /// — this is the belt to that pair of braces, and it is cheap.
    private var desiredFrame: NSRect = .zero

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

        let grid = GridViewController(document: document)
        window.contentViewController = grid

        // Order matters: `setFrameUsingName` restores a size the user chose earlier and
        // reports whether it found one, while `setFrameAutosaveName` both registers the
        // window for saving *and* restores, so it has to come second.
        let foundSavedFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // `setFrameUsingName` reports whether it *found* a saved frame, not whether it
        // applied a usable one. A frame saved against a display that has since changed
        // size is declined, and the window is left at its content view's own size — which
        // for a scroll view is nothing, so it clamps to `minSize` in a corner. Worse, the
        // autosave then writes that clamped frame back, and every future window inherits
        // it. So judge by the result rather than the return value.
        let content = window.contentRect(forFrameRect: window.frame)
        let restoredUsableFrame = foundSavedFrame
            && content.width > window.minSize.width
            && content.height > window.minSize.height

        // Sized from the grid rather than left to `fittingSize`. Applies both to a first
        // run and to repairing a saved frame that no longer works; a frame the user can
        // actually see always wins over one they once chose on another display.
        if !restoredUsableFrame {
            window.setContentSize(grid.preferredWindowContentSize)
        }

        self.hasSavedFrame = restoredUsableFrame
        super.init(window: window)

        installToolbar()

        if !document.warnings.isEmpty {
            addWarningBanner(text: ParseWarningText.summary(document.warnings))
        }

        // After the toolbar and any banner, so it includes their height.
        desiredFrame = window.frame
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
    /// Forwards to the grid. Every command on this controller calls it before reading
    /// the document — see `GridViewController.commitPendingEdit`.
    @discardableResult
    func commitPendingEdit() -> Bool {
        (contentViewController as? GridViewController)?.commitPendingEdit() ?? true
    }

    override func showWindow(_ sender: Any?) {
        shouldCascadeWindows = hasSavedFrame

        if !hasBeenPlaced {
            hasBeenPlaced = true

            // Re-asserted here because this is the first moment after AppKit's own layout
            // pass has had its say about the window's size.
            window?.setFrame(desiredFrame, display: false)
            window?.layoutIfNeeded()

            if !hasSavedFrame { window?.center() }
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
    static let dedupe = NSToolbarItem.Identifier("Dedupe")
    static let qrz = NSToolbarItem.Identifier("QRZ")
}

extension LogWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pota, .dedupe, .qrz, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pota, .dedupe, .qrz, .flexibleSpace, .space]
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
        case .dedupe:
            return toolbarItem(identifier,
                               label: "Dedupe",
                               symbol: "line.3.horizontal.decrease.circle",
                               tooltip: "Find QSOs that repeat, and delete the repeats",
                               action: #selector(findDuplicates(_:)))
        case .qrz:
            return toolbarItem(identifier,
                               label: "QRZ",
                               symbol: "person.text.rectangle",
                               tooltip: "Fill empty name, location and zone fields from "
                                      + "QRZ, for the selected QSOs or the whole log",
                               action: #selector(fillFromQRZ(_:)))
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

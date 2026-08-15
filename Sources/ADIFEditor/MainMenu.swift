import AppKit

/// The main menu, built in code because there is no nib (see `main.swift`).
///
/// Every item here targets a first-responder action AppKit already implements —
/// `openDocument:`, `saveDocument:`, `undo:`. None of them are wired to app code, which
/// is the point of using `NSDocument` at all (§5).
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(named: "ADIF Editor", items: appMenu()))
        main.addItem(submenu(named: "File", items: fileMenu()))
        main.addItem(submenu(named: "Edit", items: editMenu()))
        main.addItem(submenu(named: "POTA", items: potaMenu()))
        main.addItem(submenu(named: "Window", items: windowMenu()))
        return main
    }

    // MARK: - Menus

    private static func appMenu() -> [NSMenuItem] {
        [
            item("About ADIF Editor", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showPreferences(_:)), ","),
            .separator(),
            item("Hide ADIF Editor", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                 modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit ADIF Editor", #selector(NSApplication.terminate(_:)), "q")
        ]
    }

    private static func fileMenu() -> [NSMenuItem] {
        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recents = NSMenu(title: "Open Recent")
        // NSDocumentController finds and populates this submenu by identifier — the same
        // hook the standard nib uses.
        recents.identifier = NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu")
        recents.addItem(item("Clear Menu",
                             #selector(NSDocumentController.clearRecentDocuments(_:))))
        openRecent.submenu = recents

        return [
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            openRecent,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "S"),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        ]
    }

    private static func editMenu() -> [NSMenuItem] {
        [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            // Command-Delete rather than a bare Delete: an unmodified ⌫ as a menu
            // equivalent would be intercepted app-wide and never reach the field editor,
            // so backspace would stop deleting characters while editing a cell. The bare
            // Delete key still deletes rows — the grid handles it as a key press, which
            // only happens when the table itself has focus.
            item("Delete", #selector(GridViewController.delete(_:)), "\u{8}"),
            .separator(),
            item("Find Duplicates…", #selector(LogWindowController.findDuplicates(_:)), "d"),
            item("Fill from QRZ…", #selector(LogWindowController.fillFromQRZ(_:)), "l")
        ]
    }

    /// §10.2's command, in a menu of its own as well as on the toolbar. One item, because
    /// the park count decides between a stamp and a split (decision 16).
    private static func potaMenu() -> [NSMenuItem] {
        [
            item("Stamp Park Reference…", #selector(LogWindowController.stampForPOTA(_:)), "p")
        ]
    }

    private static func windowMenu() -> [NSMenuItem] {
        [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)))
        ]
    }

    // MARK: - Construction

    private static func submenu(named title: String, items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in items { menu.addItem(entry) }
        holder.submenu = menu
        return holder
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        return entry
    }
}

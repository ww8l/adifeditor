import AppKit

// The app is assembled in code rather than loaded from a nib. There is no Xcode on this
// machine to edit a nib with (decision 9), and a document-based app needs surprisingly
// little of one: a main menu, a delegate, and NSDocumentController doing the rest.

let application = NSApplication.shared
let delegate = AppDelegate()

application.delegate = delegate
application.setActivationPolicy(.regular)
application.mainMenu = MainMenu.build()
application.run()

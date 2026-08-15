import AppKit

/// Shared layout for the app's confirmation sheets.
///
/// Dedupe and the QRZ lookup both show the operator a list of things they are about to
/// do and let them untick any of them, which is the pattern decision 12 asks for: the app
/// proposes, the operator decides. Both lists can be long, so both need to scroll.
@MainActor
enum SheetLayout {

    /// A column of controls that scrolls once it gets long.
    ///
    /// A log can carry thirty fields and a lookup can propose several hundred fills;
    /// neither should produce a sheet taller than the screen.
    static func scrollingStack(of views: [NSView],
                               width: CGFloat,
                               maximumHeight: CGFloat = 320) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.layoutSubtreeIfNeeded()

        let contentHeight = stack.fittingSize.height
        let visibleHeight = min(contentHeight, maximumHeight)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0,
                                                    width: width, height: visibleHeight))
        scrollView.hasVerticalScroller = contentHeight > visibleHeight
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        stack.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.documentView = stack

        return scrollView
    }
}

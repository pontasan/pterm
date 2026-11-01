import AppKit

/// Window chrome policy shared by pterm windows that draw their own backdrop.
///
/// pterm owns the titlebar backdrop instead of delegating it to the system
/// titlebar material: the root content view spans the full window (including
/// the titlebar strip) so the window glass / background color extends under
/// the titlebar, while hosted content is laid out only inside
/// `contentLayoutRect` so nothing is obscured by the titlebar controls.
///
/// Relying on the system titlebar material is not acceptable because its
/// appearance changes between macOS releases (macOS 27 renders it almost fully
/// clear), which breaks pterm's dark-only visual contract.
enum WindowChrome {
    /// Style mask bits required for pterm-owned titlebar backdrops.
    static let requiredStyleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView]

    /// Configures the titlebar so that the content view's backdrop is what the
    /// user sees behind the title and traffic-light buttons.
    static func configureTitlebar(of window: NSWindow) {
        precondition(window.styleMask.contains(.titled), "WindowChrome requires a titled window")
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
    }

    /// `contentLayoutRect` after resolving pending layout.
    ///
    /// `contentLayoutRect` is derived from `contentLayoutGuide`, i.e. from the
    /// Auto Layout engine. While the window's layout is dirty it reports
    /// transient values: inserting an `NSGlassEffectView` into the content
    /// view makes it (and its KVO notification) report an origin of
    /// `-frame.height` until the next layout pass. Reading it without
    /// resolving layout first would push hosted content outside the window.
    static func resolvedContentLayoutRect(of window: NSWindow) -> NSRect {
        window.layoutIfNeeded()
        let rect = window.contentLayoutRect
        let windowBounds = NSRect(origin: .zero, size: window.frame.size)
        precondition(windowBounds.contains(rect),
                     "contentLayoutRect \(rect) lies outside window bounds \(windowBounds) after layout")
        return rect
    }

    /// Frame (in `rootView` coordinates) of the area that is not covered by
    /// titlebar chrome. `rootView` must be the window's content view.
    static func hostedContentFrame(in rootView: NSView, of window: NSWindow) -> NSRect {
        precondition(rootView.window === window, "rootView must belong to window")
        return rootView.convert(resolvedContentLayoutRect(of: window), from: nil)
    }

    /// Height consumed by titlebar chrome above the content layout area.
    static func titlebarHeight(windowFrameSize: NSSize, contentLayoutRect: NSRect) -> CGFloat {
        windowFrameSize.height - contentLayoutRect.maxY
    }

    /// Window frame size that yields a content layout area of `hostedContentSize`.
    ///
    /// `NSWindow.frameRect(forContentRect:)` cannot be used with
    /// `.fullSizeContentView` because the content view then already includes
    /// the titlebar; the titlebar height must be derived from the live
    /// `contentLayoutRect` instead.
    static func windowFrameSize(forHostedContentSize hostedContentSize: NSSize,
                                windowFrameSize: NSSize,
                                contentLayoutRect: NSRect) -> NSSize {
        let horizontalChrome = windowFrameSize.width - contentLayoutRect.width
        let verticalChrome = windowFrameSize.height - contentLayoutRect.height
        return NSSize(width: hostedContentSize.width + horizontalChrome,
                      height: hostedContentSize.height + verticalChrome)
    }

    /// Window frame size that yields a content layout area of `hostedContentSize`
    /// for the given live window.
    static func windowFrameSize(forHostedContentSize hostedContentSize: NSSize,
                                of window: NSWindow) -> NSSize {
        windowFrameSize(forHostedContentSize: hostedContentSize,
                        windowFrameSize: window.frame.size,
                        contentLayoutRect: resolvedContentLayoutRect(of: window))
    }
}

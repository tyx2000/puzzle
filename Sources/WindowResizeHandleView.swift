import AppKit

/// An explicit invisible target over the sidebar/editor divider. Keeping this
/// separate from the drawn one-pixel divider makes the interaction predictable
/// even when AppKit's effective-divider rect varies between macOS releases.
final class SplitDividerHandleView: NSView {
    static let hitWidth: CGFloat = 13

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    /// Width of the hairline this view paints over — AppKit's own divider,
    /// which has no colour API. Set from the split view's `dividerThickness`.
    var dividerThickness: CGFloat = 1 { didSet { needsDisplay = true } }
    private var initialMouseX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The handle straddles the divider, so painting its middle column replaces
    /// AppKit's fixed grey hairline with the same 1pt `Theme.border` line the
    /// activity bar and the title band draw.
    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: bounds.midX, y: 0,
               width: dividerThickness, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var paintedDividerRectForTesting: NSRect {
        NSRect(x: bounds.midX, y: 0, width: dividerThickness, height: bounds.height)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        if #available(macOS 15.0, *) {
            cursor = .columnResize
        } else {
            cursor = .resizeLeftRight
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseX = NSEvent.mouseLocation.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation.x - initialMouseX)
    }
}

/// Transparent, pointer-only resize handles just inside a full-size window.
/// The native outside border remains active; this adds a forgiving internal
/// target without changing the visible chrome or intercepting the content away
/// from the perimeter.
final class WindowResizeHandleView: NSView {
    struct Edges: OptionSet {
        let rawValue: UInt8
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    static let hitThickness: CGFloat = 8
    private static let cornerLength: CGFloat = 16

    private var activeEdges: Edges = []
    private var initialMouse = NSPoint.zero
    private var initialFrame = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !edges(at: point).isEmpty,
              window?.styleMask.contains(.resizable) == true,
              window?.styleMask.contains(.fullScreen) != true else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let t = Self.hitThickness
        let c = Self.cornerLength

        addCursorRect(NSRect(x: 0, y: c, width: t, height: max(0, bounds.height - 2 * c)),
                      cursor: horizontalCursor())
        addCursorRect(NSRect(x: bounds.maxX - t, y: c, width: t,
                             height: max(0, bounds.height - 2 * c)),
                      cursor: horizontalCursor())
        addCursorRect(NSRect(x: c, y: 0, width: max(0, bounds.width - 2 * c), height: t),
                      cursor: verticalCursor())
        addCursorRect(NSRect(x: c, y: bounds.maxY - t,
                             width: max(0, bounds.width - 2 * c), height: t),
                      cursor: verticalCursor())

        addCursorRect(NSRect(x: 0, y: 0, width: c, height: t),
                      cursor: cornerCursor(top: false, left: true))
        addCursorRect(NSRect(x: bounds.maxX - c, y: 0, width: c, height: t),
                      cursor: cornerCursor(top: false, left: false))
        addCursorRect(NSRect(x: 0, y: bounds.maxY - t, width: c, height: t),
                      cursor: cornerCursor(top: true, left: true))
        addCursorRect(NSRect(x: bounds.maxX - c, y: bounds.maxY - t,
                             width: c, height: t),
                      cursor: cornerCursor(top: true, left: false))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeEdges = edges(at: point)
        guard !activeEdges.isEmpty, let window else { return }
        initialMouse = NSEvent.mouseLocation
        initialFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty, let window else { return }
        let mouse = NSEvent.mouseLocation
        let deltaX = mouse.x - initialMouse.x
        let deltaY = mouse.y - initialMouse.y
        window.setFrame(Self.resizedFrame(initialFrame,
                                          edges: activeEdges,
                                          deltaX: deltaX,
                                          deltaY: deltaY,
                                          minimumSize: window.minSize),
                        display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
    }

    static func resizedFrame(_ original: NSRect, edges: Edges,
                             deltaX: CGFloat, deltaY: CGFloat,
                             minimumSize: NSSize) -> NSRect {
        var frame = original
        let minimumWidth = max(320, minimumSize.width)
        let minimumHeight = max(240, minimumSize.height)

        if edges.contains(.left) {
            let width = max(minimumWidth, original.width - deltaX)
            frame.origin.x = original.maxX - width
            frame.size.width = width
        } else if edges.contains(.right) {
            frame.size.width = max(minimumWidth, original.width + deltaX)
        }

        if edges.contains(.bottom) {
            let height = max(minimumHeight, original.height - deltaY)
            frame.origin.y = original.maxY - height
            frame.size.height = height
        } else if edges.contains(.top) {
            frame.size.height = max(minimumHeight, original.height + deltaY)
        }
        return frame
    }

    private func edges(at point: NSPoint) -> Edges {
        let t = Self.hitThickness
        var result: Edges = []
        if point.x <= bounds.minX + t { result.insert(.left) }
        if point.x >= bounds.maxX - t { result.insert(.right) }
        if point.y <= bounds.minY + t { result.insert(.bottom) }
        if point.y >= bounds.maxY - t { result.insert(.top) }
        return result
    }

    private func horizontalCursor() -> NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    private func verticalCursor() -> NSCursor {
        if #available(macOS 15.0, *) {
            return .rowResize
        }
        return .resizeUpDown
    }

    private func cornerCursor(top: Bool, left: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (top, left) {
            case (true, true): position = .topLeft
            case (true, false): position = .topRight
            case (false, true): position = .bottomLeft
            case (false, false): position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return horizontalCursor()
    }
}

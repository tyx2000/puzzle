import AppKit

/// A gutter that draws line numbers for a TextKit-1 backed NSTextView.
/// Numbers are drawn into each line's actual fragment rect with the editor's
/// paragraph style, so their baselines align exactly with the code — and
/// soft-wrapped continuation lines are skipped.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: PuzzleTextView?
    private var arrowHitRects: [Int: NSRect] = [:]
    private var foldableRowRects: [Int: NSRect] = [:]
    private var hoveredBlock: Int?
    private var gutterTrackingArea: NSTrackingArea?
    private var editorTrackingArea: NSTrackingArea?

    init(textView: PuzzleTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Code folding gutter")
        setAccessibilityHelp(
            "Click an arrow to fold or unfold a block. Option-Command-[ toggles the block at the caret.")

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(redraw),
                           name: NSText.didChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(redraw),
                           name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(redraw),
                           name: NSView.boundsDidChangeNotification,
                           object: textView.enclosingScrollView?.contentView)
        center.addObserver(self, selector: #selector(redraw),
                           name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let editorTrackingArea, let textView {
            textView.removeTrackingArea(editorTrackingArea)
        }
    }

    @objc private func redraw() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let gutterTrackingArea { removeTrackingArea(gutterTrackingArea) }
        if let editorTrackingArea, let textView {
            textView.removeTrackingArea(editorTrackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
        ]
        let gutterTracking = NSTrackingArea(
            rect: .zero, options: options,
            owner: self, userInfo: nil)
        addTrackingArea(gutterTracking)
        gutterTrackingArea = gutterTracking

        // VS Code-style folding controls appear when the pointer is anywhere
        // on a foldable source row, not only after finding the invisible icon.
        if let textView {
            let editorTracking = NSTrackingArea(
                rect: .zero, options: options,
                owner: self, userInfo: nil)
            textView.addTrackingArea(editorTracking)
            editorTrackingArea = editorTracking
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = foldableRowRects.first {
            point.y >= $0.value.minY && point.y < $0.value.maxY
        }?.key
        if hovered != hoveredBlock {
            hoveredBlock = hovered
            needsDisplay = true
        }

        let overArrow = bounds.contains(point) && arrowHitRects.contains {
            $0.value.contains(point)
        }
        if overArrow {
            NSCursor.pointingHand.set()
        } else if bounds.contains(point) {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let window {
            let windowPoint = window.mouseLocationOutsideOfEventStream
            let insideGutter = bounds.contains(convert(windowPoint, from: nil))
            let insideEditor = textView.map {
                $0.visibleRect.contains($0.convert(windowPoint, from: nil))
            } ?? false
            if insideGutter || insideEditor { return }
        }
        hoveredBlock = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let identity = arrowHitRects.first(where: {
            $0.value.insetBy(dx: -3, dy: -3).contains(point)
        })?.key,
              let block = textView?.codeBlocks.first(where: { $0.identity == identity }) else {
            super.mouseDown(with: event)
            return
        }
        hoveredBlock = identity
        textView?.toggleFold(block)
        needsDisplay = true
    }

    /// Take over drawing completely: NSRulerView otherwise paints a hairline
    /// separator between the gutter and the code.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        Theme.editorBackground.setFill()
        bounds.fill()
        arrowHitRects.removeAll(keepingCapacity: true)
        foldableRowRects.removeAll(keepingCapacity: true)

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Match the editor's line metrics (font, line height, baseline shift) so
        // the numbers sit on the same baseline as the code and are centered in
        // the current-line band.
        let para = NSMutableParagraphStyle()
        para.setParagraphStyle(Theme.paragraphStyle())
        para.alignment = .right
        let normal: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: Theme.gutter, .paragraphStyle: para]
        let active: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: Theme.gutterActive, .paragraphStyle: para]

        let caretLine = 1 + newlineCount(content, upTo: min(textView.selectedRange().location, content.length))

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)

        let foldableByLine = Dictionary(grouping: textView.codeBlocks, by: \.openerLineStart)
            .compactMapValues { $0.max { $0.endLocation < $1.endLocation } }
        let numberWidth = ruleThickness - 14
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragChar = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let isLineStart = fragChar.location == 0
                || content.character(at: fragChar.location - 1) == 10
            guard isLineStart else { return }  // skip wrapped continuations
            // Derive the source line from this fragment's character location.
            // Folded glyphs may skip many hard lines, so incrementing a visual
            // counter would incorrectly renumber the source after a fold.
            let lineNo = 1 + self.newlineCount(content, upTo: fragChar.location)
            let y = fragRect.minY + inset - visibleRect.minY
            let box = NSRect(x: 0, y: y, width: numberWidth, height: fragRect.height)
            ("\(lineNo)" as NSString).draw(in: box, withAttributes: lineNo == caretLine ? active : normal)
            if let block = foldableByLine[fragChar.location] {
                let rowRect = NSRect(
                    x: 0, y: y,
                    width: self.ruleThickness, height: fragRect.height)
                let hitRect = NSRect(
                    x: self.ruleThickness - 14, y: y,
                    width: 14, height: fragRect.height)
                self.foldableRowRects[block.identity] = rowRect
                self.arrowHitRects[block.identity] = hitRect

                if self.hoveredBlock == block.identity {
                    // The editor's 1.8 line height puts all extra leading above
                    // its glyphs. Center the chevron in that same glyph box,
                    // rather than in the taller line fragment.
                    let natural = layoutManager.defaultLineHeight(for: font)
                    let glyphHeight = font.ascender - font.descender
                    let glyphTop = max(0, fragRect.height - natural)
                    let centerY = y + glyphTop + glyphHeight / 2
                    let arrowRect = NSRect(
                        x: self.ruleThickness - 12,
                        y: centerY - 5,
                        width: 10, height: 10)
                    self.drawFoldArrow(
                        in: arrowRect,
                        folded: textView.isFolded(block))
                }
            }
        }
    }

    private func drawFoldArrow(in rect: NSRect, folded: Bool) {
        let path = NSBezierPath()
        path.lineWidth = 1.15
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if folded {
            path.move(to: NSPoint(x: center.x - 1.5, y: center.y - 2.5))
            path.line(to: NSPoint(x: center.x + 1.5, y: center.y))
            path.line(to: NSPoint(x: center.x - 1.5, y: center.y + 2.5))
        } else if isFlipped {
            path.move(to: NSPoint(x: center.x - 2.5, y: center.y - 1.5))
            path.line(to: NSPoint(x: center.x, y: center.y + 1.5))
            path.line(to: NSPoint(x: center.x + 2.5, y: center.y - 1.5))
        } else {
            path.move(to: NSPoint(x: center.x - 2.5, y: center.y + 1.5))
            path.line(to: NSPoint(x: center.x, y: center.y - 1.5))
            path.line(to: NSPoint(x: center.x + 2.5, y: center.y + 1.5))
        }
        Theme.gutterActive.setStroke()
        path.stroke()
    }

    private func newlineCount(_ s: NSString, upTo location: Int) -> Int {
        guard location > 0 else { return 0 }
        var count = 0
        for i in 0..<location where s.character(at: i) == 10 { count += 1 }
        return count
    }
}

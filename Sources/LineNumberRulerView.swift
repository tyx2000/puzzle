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

        // Draw numbers in the complete configured code row and centre them
        // vertically. The editor layout manager uses the same geometry.
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let normal: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: Theme.gutter, .paragraphStyle: para]
        let active: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: Theme.gutterActive, .paragraphStyle: para]

        let caretLine = 1 + newlineCount(content, upTo: min(textView.selectedRange().location, content.length))

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)

        // The active line is one row across the whole editor, so the gutter
        // paints the same band behind its number. The rect comes from the text
        // view so the two can never drift apart.
        if let band = currentLineBandRect(in: visibleRect) {
            Theme.lineHighlight.setFill()
            band.fill()
        }

        let diffNumbers = textView.diffLineNumbers
        let foldableByLine = Dictionary(grouping: textView.codeBlocks, by: \.openerLineStart)
            .compactMapValues { $0.max { $0.endLocation < $1.endLocation } }
        let numberWidth = ruleThickness - 14
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragChar = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let isLineStart = fragChar.location == 0
                || content.character(at: fragChar.location - 1) == 10
            guard isLineStart else { return }  // skip wrapped continuations
            // Markdown fence and table-separator source lines are collapsed to
            // layout control rows. Drawing their numbers into a 1pt fragment
            // stacked labels on top of the adjacent real lines.
            if let manager = layoutManager as? FoldingLayoutManager,
               manager.isMarkdownControlLineCollapsed(at: fragChar.location) {
                return
            }
            // Derive the source line from this fragment's character location.
            // Folded glyphs may skip many hard lines, so incrementing a visual
            // counter would incorrectly renumber the source after a fold.
            let lineNo = 1 + self.newlineCount(content, upTo: fragChar.location)
            let y = fragRect.minY + inset - visibleRect.minY
            // A diff buffer numbers its lines as they sit in the file, and
            // leaves the headers between hunks blank.
            let shown: Int?
            if diffNumbers.isEmpty {
                shown = lineNo
            } else {
                shown = lineNo <= diffNumbers.count ? diffNumbers[lineNo - 1] : nil
            }
            if let shown {
                let value = "\(shown)" as NSString
                let attributes = lineNo == caretLine ? active : normal
                let textHeight = value.size(withAttributes: attributes).height
                let box = NSRect(x: 0, y: y + (fragRect.height - textHeight) / 2,
                                 width: numberWidth, height: textHeight)
                value.draw(in: box, withAttributes: attributes)
            }
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
                    let centerY = y + fragRect.height / 2
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

    /// The active-line band as it falls inside the gutter, or nil when the text
    /// view is not showing one (no document, a selection rather than a caret).
    func currentLineBandRect(in visibleRect: NSRect? = nil) -> NSRect? {
        guard let textView, let band = textView.currentLineBandRect() else { return nil }
        let visible = visibleRect ?? textView.visibleRect
        return NSRect(x: 0, y: band.minY - visible.minY,
                      width: ruleThickness, height: band.height)
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

    var clientViewVisibleRectForTesting: NSRect { textView?.visibleRect ?? .zero }

    private func newlineCount(_ s: NSString, upTo location: Int) -> Int {
        guard location > 0 else { return 0 }
        var count = 0
        for i in 0..<location where s.character(at: i) == 10 { count += 1 }
        return count
    }
}

import AppKit

/// A gutter that draws line numbers for a TextKit-1 backed NSTextView.
/// Numbers are drawn into each line's actual fragment rect with the editor's
/// paragraph style, so their baselines align exactly with the code — and
/// soft-wrapped continuation lines are skipped.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46

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

    @objc private func redraw() { needsDisplay = true }

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
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Hard-line number bookkeeping: if the first visible fragment is a
        // wrapped continuation, its line start is above and already counted.
        var lineNo = newlineCount(content, upTo: charRange.location)
        let startsAtLineStart = charRange.location == 0
            || content.character(at: charRange.location - 1) == 10
        if !startsAtLineStart { lineNo += 1 }

        let numberWidth = ruleThickness - 8
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragChar = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let isLineStart = fragChar.location == 0
                || content.character(at: fragChar.location - 1) == 10
            guard isLineStart else { return }  // skip wrapped continuations
            lineNo += 1
            let y = fragRect.minY + inset - visibleRect.minY
            let box = NSRect(x: 0, y: y, width: numberWidth, height: fragRect.height)
            ("\(lineNo)" as NSString).draw(in: box, withAttributes: lineNo == caretLine ? active : normal)
        }
    }

    private func newlineCount(_ s: NSString, upTo location: Int) -> Int {
        guard location > 0 else { return 0 }
        var count = 0
        for i in 0..<location where s.character(at: i) == 10 { count += 1 }
        return count
    }
}

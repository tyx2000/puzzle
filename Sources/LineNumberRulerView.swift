import AppKit

/// A gutter that draws line numbers for a TextKit-1 backed NSTextView.
/// Numbers are drawn into each line's actual fragment rect with the editor's
/// paragraph style, so their baselines align exactly with the code — and
/// soft-wrapped continuation lines are skipped.
final class LineNumberRulerView: NSRulerView {
    /// Uncommitted changes for the file on screen, marked beside their lines.
    var gitChanges: [GitLineChanges.Change] = [] {
        didSet { needsDisplay = true }
    }
    /// Asked to explain the change on a line the user clicked.
    var onChangeClicked: ((GitLineChanges.Change, NSRect) -> Void)?
    /// Gutter columns, outer edge inward:
    ///
    ///     [ divider reach ][ ribbon ][ line numbers ][ fold arrow ]
    ///
    /// The first band belongs to the split divider's drag handle, which is
    /// centred on the boundary and reaches into the editor; anything drawn or
    /// clicked there is really the resize target. The last belongs to the fold
    /// arrow. The ribbon and the numbers live between them, so all three
    /// targets are reachable without fighting each other.
    static let dividerReach: CGFloat = 8
    static let changeMarkWidth: CGFloat = 3
    /// Widened under the pointer. Stops short of the numbers, which keep their
    /// column: the ribbon grows into the gap, it does not push anything.
    static let changeMarkHoverWidth: CGFloat = 8
    static let foldArrowColumn: CGFloat = 14
    /// Never narrower than this, however short the file: a one-digit column
    /// reads as a stray character rather than a gutter, and a file one line
    /// from `9` to `10` would shift the code sideways.
    static let minimumDigits = 2

    /// Where the line numbers start and end inside the gutter.
    static func numberColumn(digits: Int,
                             font: NSFont = Theme.editorFont()) -> (start: CGFloat, end: CGFloat) {
        // Room for the ribbon at its hovered width, so growing it never runs
        // under the widest line number.
        (dividerReach + changeMarkHoverWidth + 2,
         gutterWidth(for: font, digits: digits) - foldArrowColumn)
    }

    /// Wide enough for the widest number this file will actually show, plus the
    /// columns either side of it. Derived rather than fixed: a fixed four-digit
    /// column charged a 90-line file for digits it never draws, and
    /// `buffer_font_size` moves the requirement anyway.
    static func gutterWidth(for font: NSFont = Theme.editorFont(),
                            digits: Int = 4) -> CGFloat {
        let sample = String(repeating: "8", count: max(digits, minimumDigits))
        let width = ceil((sample as NSString).size(withAttributes: [.font: font]).width)
        return dividerReach + changeMarkHoverWidth + 2 + width + 4 + foldArrowColumn
    }

    /// Digits needed to write the highest line number in the file.
    static func digits(forHighestLine line: Int) -> Int {
        max(minimumDigits, String(max(line, 1)).count)
    }

    private var changeMarkRects: [(change: GitLineChanges.Change, rect: NSRect)] = []
    /// Where the ribbon itself was painted, as opposed to its click target.
    private var changeMarkBars: [NSRect] = []
    private weak var textView: PuzzleTextView?
    private var arrowHitRects: [Int: NSRect] = [:]
    private var foldableRowRects: [Int: NSRect] = [:]
    private var hoveredBlock: Int?
    /// The change under the pointer, kept by its line range so it survives the
    /// redraws that rebuild the mark rects.
    private var hoveredChange: GitLineChanges.Change?
    private var hoverProgress: CGFloat = 0
    /// The one the pointer just left, so it shrinks back instead of snapping.
    private var fadingChange: GitLineChanges.Change?
    private var fadingProgress: CGFloat = 0
    private var hoverTimer: Timer?

    /// Long enough to read as movement, short enough not to lag the pointer.
    static let hoverAnimationDuration: CGFloat = 0.12

    /// Ribbon width at a point in the transition, eased so it starts fast and
    /// settles rather than arriving at constant speed.
    static func markWidth(progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        let eased = 1 - (1 - clamped) * (1 - clamped)
        return changeMarkWidth + (changeMarkHoverWidth - changeMarkWidth) * eased
    }

    private func markWidth(for change: GitLineChanges.Change) -> CGFloat {
        if change.lines == hoveredChange?.lines { return Self.markWidth(progress: hoverProgress) }
        if change.lines == fadingChange?.lines { return Self.markWidth(progress: fadingProgress) }
        return Self.changeMarkWidth
    }

    private func setHoveredChange(_ change: GitLineChanges.Change?) {
        guard change?.lines != hoveredChange?.lines else { return }
        // Whatever was growing starts shrinking from where it got to, so a
        // pointer sweeping down the gutter leaves a trail that settles.
        if let previous = hoveredChange {
            fadingChange = previous
            fadingProgress = hoverProgress
        }
        hoveredChange = change
        hoverProgress = 0
        needsDisplay = true
        startHoverAnimation()
    }

    private func startHoverAnimation() {
        hoverTimer?.invalidate()
        guard window != nil else {
            // Off screen there is nothing to animate; land on the end state.
            hoverProgress = hoveredChange == nil ? 0 : 1
            fadingChange = nil
            fadingProgress = 0
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let step = 1 / (Self.hoverAnimationDuration * 60)
            if self.hoveredChange != nil {
                self.hoverProgress = min(1, self.hoverProgress + step)
            }
            self.fadingProgress = max(0, self.fadingProgress - step)
            if self.fadingProgress == 0 { self.fadingChange = nil }
            self.needsDisplay = true
            let growing = self.hoveredChange != nil && self.hoverProgress < 1
            if !growing, self.fadingChange == nil {
                timer.invalidate()
                self.hoverTimer = nil
            }
        }
        hoverTimer = timer
        // Common mode: the ribbon keeps animating while the pointer is tracked.
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Line count for rulers with no document index behind them (the history
    /// pane), rebuilt only when the text changes.
    private var cachedLineCount: (length: Int, lines: Int)?
    private var gutterTrackingArea: NSTrackingArea?
    private var editorTrackingArea: NSTrackingArea?

    init(textView: PuzzleTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.gutterWidth(digits: Self.minimumDigits)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Code folding gutter")
        setAccessibilityHelp(
            "Click an arrow to fold or unfold a block. Option-Command-[ toggles the block at the caret.")

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged),
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
        hoverTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let editorTrackingArea, let textView {
            textView.removeTrackingArea(editorTrackingArea)
        }
    }

    @objc private func redraw() {
        updateThickness()
        needsDisplay = true
    }

    @objc private func textChanged() {
        cachedLineCount = nil
        redraw()
    }

    /// The gutter is sized from the font, which can change under us
    /// (settings.json), and from the file's own line count, which grows as the
    /// user types. Done before drawing rather than during it, so the width the
    /// numbers are laid out against is the width the ruler actually has.
    override func viewWillDraw() {
        super.viewWillDraw()
        updateThickness()
    }

    private func updateThickness() {
        let width = Self.gutterWidth(digits: currentDigits)
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    /// Digits the file on screen needs. A diff buffer numbers its lines as they
    /// sit in the original file, so its widest number is not its length.
    private var currentDigits: Int {
        Self.digits(forHighestLine: highestLineNumber)
    }

    private var highestLineNumber: Int {
        guard let textView else { return 1 }
        let diff = textView.diffLineNumbers
        if !diff.isEmpty { return diff.compactMap { $0 }.max() ?? 1 }
        if let index = lineIndexProvider?() { return index.lineCount }
        let content = textView.string as NSString
        if let cached = cachedLineCount, cached.length == content.length { return cached.lines }
        let lines = LineIndex(content).lineCount
        cachedLineCount = (content.length, lines)
        return lines
    }

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
        // The ribbon is 3pt wide — enough to read, not enough to aim at. Under
        // the pointer it grows to the right, into the space between it and the
        // line number, so the thing you are about to click looks like a target.
        let change = overArrow ? nil : changeMarkRects.first { $0.rect.contains(point) }?.change
        setHoveredChange(change)
        if overArrow || change != nil {
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
        setHoveredChange(nil)
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The fold arrow wins where they overlap; it is the smaller target.
        if !arrowHitRects.contains(where: { $0.value.insetBy(dx: -3, dy: -3).contains(point) }),
           let hit = changeMarkRects.first(where: { $0.rect.contains(point) }) {
            onChangeClicked?(hit.change, hit.rect)
            return
        }
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
        changeMarkRects.removeAll(keepingCapacity: true)
        changeMarkBars.removeAll(keepingCapacity: true)

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

        // Line numbers come from the document's index. Counting newlines here
        // was O(file) per visible row — every gutter draw walked the whole
        // buffer dozens of times.
        let index = lineIndexProvider?() ?? LineIndex(content)
        let caretLine = index.line(at: min(textView.selectedRange().location, content.length))

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
        let numbers = Self.numberColumn(digits: currentDigits, font: font)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragChar = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let isLineStart = fragChar.location == 0
                || content.character(at: fragChar.location - 1) == 10
            guard isLineStart else { return }  // skip wrapped continuations
            // Derive the source line from this fragment's character location.
            // Folded glyphs may skip many hard lines, so incrementing a visual
            // counter would incorrectly renumber the source after a fold.
            let lineNo = index.line(at: fragChar.location)
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
                let box = NSRect(x: numbers.start,
                                 y: y + (fragRect.height - textHeight) / 2,
                                 width: numbers.end - numbers.start,
                                 height: textHeight)
                value.draw(in: box, withAttributes: attributes)
            }
            // The change ribbon runs along the outer edge of the gutter. It used
            // to sit against the code, where it shared a column with the fold
            // arrow and stole its clicks on any line that had changed.
            if let change = GitLineChanges.change(at: lineNo, in: self.gitChanges) {
                let width = self.markWidth(for: change)
                let markRect = NSRect(x: Self.dividerReach, y: y,
                                      width: width, height: fragRect.height)
                change.colour.setFill()
                if change.kind == .deleted {
                    // Nothing occupies the line any more, so mark the seam
                    // rather than the whole row.
                    let seam = NSRect(x: markRect.minX, y: markRect.minY,
                                      width: markRect.width, height: 3)
                    NSBezierPath(roundedRect: seam, xRadius: 1.5, yRadius: 1.5).fill()
                } else {
                    NSBezierPath(roundedRect: markRect, xRadius: 1.5, yRadius: 1.5).fill()
                }
                self.changeMarkBars.append(markRect)
                // The ribbon is 3pt wide; the target is the ribbon plus the
                // number column, which clears the divider handle on one side
                // and the fold arrow on the other.
                self.changeMarkRects.append(
                    (change, NSRect(x: Self.dividerReach, y: y,
                                    width: numbers.end - Self.dividerReach,
                                    height: fragRect.height)))
            }
            if let block = foldableByLine[fragChar.location] {
                let rowRect = NSRect(
                    x: 0, y: y,
                    width: self.ruleThickness, height: fragRect.height)
                let hitRect = NSRect(
                    x: self.ruleThickness - Self.foldArrowColumn, y: y,
                    width: Self.foldArrowColumn, height: fragRect.height)
                self.foldableRowRects[block.identity] = rowRect
                self.arrowHitRects[block.identity] = hitRect

                if self.hoveredBlock == block.identity {
                    let centerY = y + fragRect.height / 2
                    let arrowRect = NSRect(
                        x: self.ruleThickness - Self.foldArrowColumn + 2,
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
    var changeMarkCountForTesting: Int { changeMarkRects.count }
    var changeMarkTargetsForTesting: [NSRect] { changeMarkRects.map(\.rect) }
    /// Pretend the pointer is on the change covering `line`.
    func hoverChangeForTesting(at line: Int?) {
        setHoveredChange(line.flatMap { GitLineChanges.change(at: $0, in: gitChanges) })
    }
    var hoverIsAnimatingForTesting: Bool { hoverTimer != nil }
    func settleHoverForTesting() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverProgress = hoveredChange == nil ? 0 : 1
        fadingChange = nil
        fadingProgress = 0
        needsDisplay = true
    }
    var changeMarkBarsForTesting: [NSRect] { changeMarkBars }
    func clickChangeForTesting(at line: Int) -> Bool {
        guard let change = GitLineChanges.change(at: line, in: gitChanges) else { return false }
        onChangeClicked?(change, NSRect(x: 0, y: 0, width: ruleThickness, height: 20))
        return true
    }

    /// Asked for on each draw rather than handed over once: the document's
    /// index changes with every edit, and a copy taken at open time would
    /// number the lines as they were before the user started typing.
    var lineIndexProvider: (() -> LineIndex?)?

    private func newlineCount(_ s: NSString, upTo location: Int) -> Int {
        guard location > 0 else { return 0 }
        var count = 0
        for i in 0..<location where s.character(at: i) == 10 { count += 1 }
        return count
    }
}

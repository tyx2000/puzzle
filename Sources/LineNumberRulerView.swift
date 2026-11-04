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

    /// The change whose diff panel is open, and the panel: while it is up the
    /// gutter joins the change's mark to the panel's edge, in the change's
    /// colour — the panel opens below the lines, a little way from the mark
    /// that was clicked, and nothing said the two belonged together.
    private var linkedChange: GitLineChanges.Change?
    private weak var linkedPanel: NSWindow?
    /// How strongly the join is filled: enough to see the two are one, light
    /// enough that the line numbers under it still read.
    static let changeLinkAlpha: CGFloat = 0.28

    func linkChange(_ change: GitLineChanges.Change?, to panel: NSWindow?) {
        // From one change to another: the mark's end of the join slides from
        // the old mark to the new one, in step with the panel moving — or,
        // with Reduce Motion on, jumps there as the panel does.
        if let drawn = lastLink, let change, linkedChange != nil, linkedChange != change,
           !GitChangePanel.reducesMotion {
            linkTransition = (drawn.span, drawn.colour, CACurrentMediaTime(),
                              GitChangePanel.moveDuration)
        } else {
            linkTransition = nil
        }
        linkedChange = change
        linkedPanel = panel
        needsDisplay = true
    }

    /// The join as last drawn, to slide from.
    private var lastLink: (span: ClosedRange<CGFloat>, colour: NSColor)?
    private var linkTransition: (span: ClosedRange<CGFloat>, colour: NSColor,
                                 start: CFTimeInterval, duration: CFTimeInterval)?

    /// Whether `event` is a click on a change's mark — which moves the open
    /// diff there rather than putting it away.
    func isChangeMark(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return changeMarkRects.contains { $0.rect.contains(point) }
    }

    /// How many times the gutter has drawn, for a test to tell a join that
    /// followed the panel frame by frame from one drawn only at the ends.
    private(set) var drawsForTesting = 0

    /// What the last draw joined: the shape's bounds, and its colour.
    private(set) var changeLinkForTesting: (bounds: NSRect, colour: NSColor)?
    /// Gutter columns, outer edge inward:
    ///
    ///     [ divider reach ][ ribbon ][ gap ][ clickable line numbers ]
    ///
    /// The first band belongs to the split divider's drag handle, which is
    /// centred on the boundary and reaches into the editor; anything drawn or
    /// clicked there is really the resize target. The number's badge keeps
    /// clear of the ribbon, which alone opens the line's change. The handle takes
    /// hold only at its knob, which is centred on the line and reaches half
    /// its width past it.
    static let dividerReach: CGFloat = DividerGrip.radius
    /// The ribbon's one width. It was 3pt and grew to this under the pointer;
    /// it is this wide throughout now, so the target never has to be found
    /// first. Stops short of the numbers, which keep their column.
    static let changeMarkWidth: CGFloat = 8
    private static let numberBadgePadding: CGFloat = 5
    private static let numberColumnGap: CGFloat = 3
    private static let trailingInset: CGFloat = 3
    /// Never narrower than this, however short the file: a one-digit column
    /// reads as a stray character rather than a gutter, and a file one line
    /// from `9` to `10` would shift the code sideways.
    static let minimumDigits = 2

    /// Where the line numbers start and end inside the gutter.
    static func numberColumn(digits: Int,
                             font: NSFont = Theme.editorFont()) -> (start: CGFloat, end: CGFloat) {
        // Room for the ribbon, so it never runs under the widest line number.
        (dividerReach + changeMarkWidth + numberColumnGap + numberBadgePadding,
         gutterWidth(for: font, digits: digits) - trailingInset - numberBadgePadding)
    }

    /// Wide enough for the widest number this file will actually show, plus the
    /// columns either side of it. Derived rather than fixed: a fixed four-digit
    /// column charged a 90-line file for digits it never draws, and
    /// `buffer_font_size` moves the requirement anyway.
    static func gutterWidth(for font: NSFont = Theme.editorFont(),
                            digits: Int = 4) -> CGFloat {
        let sample = String(repeating: "8", count: max(digits, minimumDigits))
        let width = ceil((sample as NSString).size(withAttributes: [.font: font]).width)
        return dividerReach + changeMarkWidth + numberColumnGap
            + numberBadgePadding * 2 + width + trailingInset
    }

    /// Digits needed to write the highest line number in the file.
    static func digits(forHighestLine line: Int) -> Int {
        max(minimumDigits, String(max(line, 1)).count)
    }

    private var changeMarkRects: [(change: GitLineChanges.Change, rect: NSRect)] = []
    /// Where the ribbon itself was painted, as opposed to its click target.
    private var changeMarkBars: [NSRect] = []
    private weak var textView: PuzzleTextView?
    private struct NumberRow: Equatable {
        let line: Int
        let number: Int
        let hitRect: NSRect
        let labelBox: NSRect
        let pill: NSRect
        let blockIdentity: Int?
    }
    private var numberRows: [NumberRow] = []
    private var hoveredNumber: NumberRow?
    private var displayedHoverMark: NSRect?
    private var hoverTimer: Timer?
    private var hoverLastTick: CFTimeInterval?
    private var hoverNeedsRealignment = true
    private static let hoverResponseTime: TimeInterval = 0.03
    private(set) var pointingHandForTesting = false
    private var cachedCodeBlocks: [CodeBlock] = []
    private var foldableByLine: [Int: CodeBlock] = [:]
    /// Line count for rulers with no document index behind them (the history
    /// pane), rebuilt only when the text changes.
    private var cachedLineCount: (length: Int, lines: Int)?
    private var gutterTrackingArea: NSTrackingArea?

    init(textView: PuzzleTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.gutterWidth(digits: Self.minimumDigits)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Code folding gutter")
        setAccessibilityHelp(
            "Click the line number at the start of a block to fold or unfold it. Option-Command-[ toggles the block at the caret.")

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
        NotificationCenter.default.removeObserver(self)
        hoverTimer?.invalidate()
    }

    @objc private func redraw() {
        hoverNeedsRealignment = true
        stopHoverMovement()
        hoveredNumber = nil
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
        let options: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
        ]
        let gutterTracking = NSTrackingArea(
            rect: .zero, options: options,
            owner: self, userInfo: nil)
        addTrackingArea(gutterTracking)
        gutterTrackingArea = gutterTracking
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil), animated: true)
    }

    func refreshHoverState() {
        guard let window else {
            setHoveredNumber(nil, animated: false)
            pointingHandForTesting = false
            return
        }
        updateHover(at: convert(window.pointerLocation, from: nil), animated: !hoverNeedsRealignment)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredNumber(nil, animated: false)
        pointingHandForTesting = false
        // The destination view owns its cursor; in particular, do not replace
        // the editor's I-beam or a floating button's hand on the way out.
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverNeedsRealignment = true
        if window == nil {
            setHoveredNumber(nil, animated: false)
            pointingHandForTesting = false
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for row in numberRows where row.blockIdentity != nil {
            addCursorRect(row.hitRect, cursor: .pointingHand)
        }
        for mark in changeMarkRects { addCursorRect(mark.rect, cursor: .pointingHand) }
    }

    private func updateHover(at point: NSPoint, animated: Bool) {
        let row = bounds.contains(point) ? numberRows.first { $0.hitRect.contains(point) } : nil
        setHoveredNumber(row, animated: animated)
        pointingHandForTesting = row?.blockIdentity != nil
            || changeMarkRects.contains { $0.rect.contains(point) }
        if bounds.contains(point) {
            (pointingHandForTesting ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    private func setHoveredNumber(_ row: NumberRow?, animated: Bool) {
        let canAnimate = animated && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard row != hoveredNumber else {
            if !canAnimate { stopHoverMovement() }
            return
        }
        let shown = displayedHoverPill
        hoveredNumber = row
        guard canAnimate, let shown, let row, abs(shown.minY - row.pill.minY) > 0.25 else {
            stopHoverMovement()
            needsDisplay = true
            return
        }
        displayedHoverMark = shown
        if hoverTimer == nil {
            hoverLastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.advanceHoverMark()
            }
            hoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func advanceHoverMark() {
        guard let row = hoveredNumber, let shown = displayedHoverMark,
              window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopHoverMovement()
            needsDisplay = true
            return
        }
        let time = CACurrentMediaTime()
        let elapsed = max(0, time - (hoverLastTick ?? time))
        hoverLastTick = time
        let amount = CGFloat(-expm1(-elapsed / Self.hoverResponseTime))
        displayedHoverMark = NSRect(
            x: row.pill.minX, y: shown.minY + (row.pill.minY - shown.minY) * amount,
            width: row.pill.width, height: shown.height + (row.pill.height - shown.height) * amount)
        if let displayedHoverMark,
           max(abs(displayedHoverMark.minY - row.pill.minY),
               abs(displayedHoverMark.height - row.pill.height)) <= 0.25 { stopHoverMovement() }
        needsDisplay = true
    }

    private func stopHoverMovement() {
        let wasMoving = hoverTimer != nil || displayedHoverMark != nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverLastTick = nil
        displayedHoverMark = nil
        if wasMoving { needsDisplay = true }
    }

    private func foldNumber(at point: NSPoint) -> Bool {
        guard let identity = numberRows.first(where: { $0.hitRect.contains(point) })?.blockIdentity,
              let textView, textView.isEditable, textView.diffLineNumbers.isEmpty,
              let block = textView.codeBlocks.first(where: { $0.identity == identity }) else { return false }
        textView.toggleFold(block)
        hoverNeedsRealignment = true
        stopHoverMovement()
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if hoverNeedsRealignment {
            layoutSubtreeIfNeeded()
            displayIfNeeded()
        }
        let point = convert(event.locationInWindow, from: nil)
        if numberRows.contains(where: { $0.hitRect.contains(point) }) {
            _ = foldNumber(at: point)
            return
        }
        if let hit = changeMarkRects.first(where: { $0.rect.contains(point) }) {
            onChangeClicked?(hit.change, rows(of: hit.change) ?? hit.rect)
            return
        }
        super.mouseDown(with: event)
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

        drawsForTesting += 1
        Theme.editorBackground.setFill()
        bounds.fill()
        let previousNumberRows = numberRows
        let previousChangeTargets = changeMarkRects.map(\.rect)
        numberRows.removeAll(keepingCapacity: true)
        changeMarkRects.removeAll(keepingCapacity: true)
        changeMarkBars.removeAll(keepingCapacity: true)
        drawnLineNumbersForTesting.removeAll(keepingCapacity: true)

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Draw numbers in the complete configured code row and centre them
        // vertically. The editor layout manager uses the same geometry.
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let normal: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: Theme.gutter, .paragraphStyle: para]
        // The caret's number is drawn plain like the rest, then covered by its
        // badge after them: a solid pill of the accent, the number on it in
        // the code's ground.
        let badge: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: Theme.editorBackground, .paragraphStyle: para]

        // Line numbers come from the document's index. Counting newlines here
        // was O(file) per visible row — every gutter draw walked the whole
        // buffer dozens of times.
        let index = lineIndexProvider?() ?? LineIndex(content)
        let caretLine = index.line(at: min(textView.selectedRange().location, content.length))

        let visibleRect = textView.visibleRect
        // The gutter follows vertical scrolling only. Horizontal scrolling
        // past a short line's last glyph must not hide its number or Git mark.
        let rulerRect = NSRect(x: 0, y: visibleRect.minY,
                               width: textView.bounds.width, height: visibleRect.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rulerRect, in: container)

        // Where the caret's line is drawn in this pass, for its badge.
        var caretRow: (y: CGFloat, height: CGFloat)?


        let diffNumbers = textView.diffLineNumbers
        if cachedCodeBlocks != textView.codeBlocks {
            cachedCodeBlocks = textView.codeBlocks
            foldableByLine.removeAll(keepingCapacity: true)
            for block in cachedCodeBlocks {
                if let previous = foldableByLine[block.openerLineStart],
                   previous.endLocation >= block.endLocation { continue }
                foldableByLine[block.openerLineStart] = block
            }
        }
        let numbers = Self.numberColumn(digits: currentDigits, font: font)
        // Changed lines next to each other, of one kind, are one ribbon: drawn
        // a row at a time, each row's rounded ends made a dashed line of what
        // is a single block of change. A wrapped line's ribbon runs down all
        // of its rows.
        var ribbon: (rect: NSRect, change: GitLineChanges.Change, line: Int)?
        var currentLine = 0
        func flushRibbon() {
            guard let drawn = ribbon else { return }
            drawn.change.colour.setFill()
            NSBezierPath(roundedRect: drawn.rect, xRadius: 1.5, yRadius: 1.5).fill()
            self.changeMarkBars.append(drawn.rect)
            ribbon = nil
        }
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragChar = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let isLineStart = fragChar.location == 0
                || content.character(at: fragChar.location - 1) == 10
            guard isLineStart else {
                // A wrapped continuation: no number, but the line's ribbon
                // and its click target carry on down it.
                let y = fragRect.minY + inset - visibleRect.minY
                if let drawn = ribbon, drawn.line == currentLine,
                   abs(drawn.rect.maxY - y) < 0.5 {
                    ribbon?.rect.size.height += fragRect.height
                    self.changeMarkRects.append(
                        (drawn.change, NSRect(x: Self.dividerReach, y: y,
                                              width: Self.changeMarkWidth,
                                              height: fragRect.height)))
                }
                return
            }
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
            let lineNo = index.line(at: fragChar.location)
            currentLine = lineNo
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
                self.drawnLineNumbersForTesting.append(shown)
                let value = "\(shown)" as NSString
                if lineNo == caretLine { caretRow = (y, fragRect.height) }
                let attributes = normal
                let size = value.size(withAttributes: attributes)
                let box = NSRect(x: numbers.start,
                                 y: y + (fragRect.height - size.height) / 2,
                                 width: numbers.end - numbers.start,
                                 height: size.height)
                let hit = NSRect(x: numbers.start - Self.numberBadgePadding, y: y,
                                 width: numbers.end - numbers.start + Self.numberBadgePadding * 2,
                                 height: fragRect.height)
                let identity = textView.isEditable && diffNumbers.isEmpty
                    ? self.foldableByLine[fragChar.location]?.identity : nil
                self.numberRows.append(NumberRow(line: lineNo, number: shown, hitRect: hit,
                                                 labelBox: box,
                                                 pill: Self.activePill(around: box, textWidth: size.width),
                                                 blockIdentity: identity))
                value.draw(in: box, withAttributes: attributes)
            }
            // The change ribbon alone opens its diff. The number column is
            // reserved for folding and must never share that click target.
            let change = GitLineChanges.change(at: lineNo, in: self.gitChanges)
            if let change {
                let markRect = NSRect(x: Self.dividerReach, y: y,
                                      width: Self.changeMarkWidth, height: fragRect.height)
                if change.kind == .deleted {
                    flushRibbon()
                    // Nothing occupies the line any more, so mark the seam
                    // rather than the whole row.
                    let seam = NSRect(x: markRect.minX, y: markRect.minY,
                                      width: markRect.width, height: 3)
                    change.colour.setFill()
                    NSBezierPath(roundedRect: seam, xRadius: 1.5, yRadius: 1.5).fill()
                    self.changeMarkBars.append(markRect)
                } else if let drawn = ribbon, drawn.change.kind == change.kind,
                          abs(drawn.rect.maxY - y) < 0.5 {
                    ribbon?.rect.size.height += fragRect.height
                    ribbon?.line = lineNo
                    ribbon?.change = change
                } else {
                    flushRibbon()
                    ribbon = (markRect, change, lineNo)
                }
                self.changeMarkRects.append(
                    (change, NSRect(x: Self.dividerReach, y: y,
                                    width: Self.changeMarkWidth,
                                    height: fragRect.height)))
            }
            if change == nil { flushRibbon() }
        }
        flushRibbon()
        drawChangeLink()

        if hoverNeedsRealignment || previousNumberRows != numberRows
            || previousChangeTargets != changeMarkRects.map(\.rect) {
            hoverNeedsRealignment = false
            if let window {
                window.invalidateCursorRects(for: self)
                updateHover(at: convert(window.pointerLocation, from: nil), animated: false)
            } else {
                setHoveredNumber(nil, animated: false)
            }
        }

        // The badge, found at a glance the way the open file's frame and its
        // tab are. It rides with the band the code draws behind the caret's
        // line, flying when that does; where the code draws none — a diff, a
        // selection — it sits on the caret's row.
        drawnActiveMarkForTesting = nil
        drawnHoverMarkForTesting = nil
        // Search can light a result other than the caret's row; its band
        // must not carry the caret's number onto that result.
        let movingRow = textView.searchResultLineLocation == nil
            ? textView.displayedCurrentLineBandRect() : nil
        let row = movingRow
            .map { (y: $0.minY - visibleRect.minY, height: $0.height) } ?? caretRow
        let caretNumber: Int? = diffNumbers.isEmpty
            ? caretLine : (caretLine <= diffNumbers.count ? diffNumbers[caretLine - 1] : nil)
        if let row, let caretNumber {
            let value = "\(caretNumber)" as NSString
            let size = value.size(withAttributes: badge)
            let box = NSRect(x: numbers.start, y: row.y + (row.height - size.height) / 2,
                             width: numbers.end - numbers.start, height: size.height)
            let pill = Self.activePill(around: box, textWidth: size.width)
            // Two opaque badges can cross, but their digits must not overlap.
            if displayedHoverPill.map({ !$0.intersects(pill) }) ?? true {
                Theme.cursor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                value.draw(in: box, withAttributes: badge)
                drawnActiveMarkForTesting = pill
            }
        }
        if let hoveredNumber, let pill = displayedHoverPill {
            let value = "\(hoveredNumber.number)" as NSString
            var box = hoveredNumber.labelBox
            box.origin.y = pill.midY - box.height / 2
            Theme.cursor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            value.draw(in: box, withAttributes: badge)
            drawnHoverMarkForTesting = pill
        }
    }

    /// From the right of the change's mark, top and bottom, curving to the
    /// panel's left edge, top and bottom — wherever the panel opened, below
    /// the lines or above them.
    private func drawChangeLink() {
        changeLinkForTesting = nil
        guard let change = linkedChange, let panel = linkedPanel, panel.isVisible,
              let window else {
            lastLink = nil
            return
        }
        guard let span = rows(of: change) else { return }
        // A deletion's mark is the seam at the top of its line.
        var top = span.minY
        var bottom = change.kind == .deleted ? span.minY + 3 : span.maxY
        var hue = change.colour
        if let transition = linkTransition {
            let elapsed = (CACurrentMediaTime() - transition.start) / transition.duration
            let t = CGFloat(min(1, max(0, elapsed)))
            // Eased in and out, as the panel's own move is.
            let eased = t * t * (3 - 2 * t)
            top = transition.span.lowerBound + (top - transition.span.lowerBound) * eased
            bottom = transition.span.upperBound + (bottom - transition.span.upperBound) * eased
            hue = transition.colour.blended(withFraction: eased, of: change.colour) ?? change.colour
            if t >= 1 { linkTransition = nil }
        }
        lastLink = (top...bottom, hue)
        let edge = convert(window.convertFromScreen(panel.frame), from: nil)
        let left = Self.dividerReach
        let right = left + Self.changeMarkWidth
        let gutter = bounds.maxX
        let middle = (right + gutter) / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left, y: top))
        path.line(to: NSPoint(x: right, y: top))
        path.curve(to: NSPoint(x: gutter, y: edge.minY),
                   controlPoint1: NSPoint(x: middle, y: top),
                   controlPoint2: NSPoint(x: middle, y: edge.minY))
        path.line(to: NSPoint(x: gutter, y: edge.maxY))
        path.curve(to: NSPoint(x: right, y: bottom),
                   controlPoint1: NSPoint(x: middle, y: edge.maxY),
                   controlPoint2: NSPoint(x: middle, y: bottom))
        path.line(to: NSPoint(x: left, y: bottom))
        path.close()
        // And it fades with the panel as it comes and goes.
        let colour = hue.withAlphaComponent(Self.changeLinkAlpha * panel.alphaValue)
        colour.setFill()
        path.fill()
        changeLinkForTesting = (path.bounds, colour)
    }

    /// What the last draw put under the caret's line number, and the band
    /// across its row, so they can be checked without reading pixels out of a
    /// bitmap.
    private(set) var drawnActiveMarkForTesting: NSRect?
    private(set) var drawnHoverMarkForTesting: NSRect?
    private(set) var drawnLineNumbersForTesting: [Int] = []
    var hoveredLineNumberForTesting: Int? { hoveredNumber?.line }
    var foldableNumberLinesForTesting: [Int] {
        numberRows.filter { $0.blockIdentity != nil }.map(\.line)
    }
    func numberHitRectForTesting(at line: Int) -> NSRect? {
        numberRows.first { $0.line == line }?.hitRect
    }
    private var displayedHoverPill: NSRect? {
        guard let row = hoveredNumber else { return nil }
        guard hoverTimer != nil, let displayedHoverMark else { return row.pill }
        return NSRect(x: row.pill.minX, y: displayedHoverMark.minY,
                      width: row.pill.width, height: displayedHoverMark.height)
    }
    var displayedHoverMarkForTesting: NSRect? { displayedHoverPill }
    var isHoverMarkMovingForTesting: Bool { hoverTimer != nil }

    func clickNumberForTesting(at line: Int) -> Bool {
        guard let row = numberRows.first(where: { $0.line == line }), row.blockIdentity != nil,
              let window,
              let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: convert(NSPoint(x: row.hitRect.midX, y: row.hitRect.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        mouseDown(with: event)
        return true
    }

    /// The badge behind the caret's line number: round the digits, right
    /// aligned with them so it does not shift as the caret moves between lines
    /// of different widths.
    static func activePill(around box: NSRect, textWidth: CGFloat) -> NSRect {
        let width = max(ceil(textWidth), 6)
        return NSRect(x: box.maxX - width, y: box.minY, width: width, height: box.height)
            .insetBy(dx: -5, dy: -3)
    }

    var clientViewVisibleRectForTesting: NSRect { textView?.visibleRect ?? .zero }
    var changeMarkTargetsForTesting: [NSRect] { changeMarkRects.map(\.rect) }
    var changeMarkBarsForTesting: [NSRect] { changeMarkBars }
    /// A click on the change's mark — on its row as last drawn, as a click
    /// would land, or a stand-in row when it has not been drawn.
    func clickChangeForTesting(at line: Int) -> Bool {
        guard let change = GitLineChanges.change(at: line, in: gitChanges) else { return false }
        // Through the click itself when the mark is on screen.
        if let row = changeMarkRects.first(where: { $0.change == change })?.rect,
           let window,
           let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: convert(NSPoint(x: row.midX, y: row.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) {
            mouseDown(with: click)
            return true
        }
        onChangeClicked?(change, NSRect(x: 0, y: 0, width: ruleThickness, height: 20))
        return true
    }

    /// Every row of a change as last drawn, as one rectangle: the panel opens
    /// past the whole change, not under whichever of its rows was clicked —
    /// under the first, it covered the rest.
    private func rows(of change: GitLineChanges.Change) -> NSRect? {
        let rows = changeMarkRects.filter { $0.change == change }.map(\.rect)
        guard let first = rows.first else { return nil }
        return rows.dropFirst().reduce(first) { $0.union($1) }
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

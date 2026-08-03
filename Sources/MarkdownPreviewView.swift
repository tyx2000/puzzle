import AppKit

/// Read-only rendered markdown, shown beside the source in a split.
///
/// Re-rendering is debounced: typing fires `textDidChange` per keystroke, and
/// re-parsing a long README on each one is wasted work when only the last one
/// is ever seen.
final class MarkdownPreviewView: NSView {
    /// Rendering creates a byte copy plus a second attributed document. Keep the
    /// optional preview below a size where those representations dominate RAM.
    static let maxSourceCharacters = 2_000_000

    private let scrollView = NSScrollView()
    private let textView = MarkdownTextView()
    private var pending: DispatchWorkItem?
    private var lastSource: String?
    private var renderGeneration = 0

    /// How long typing must pause before the preview re-renders.
    private let debounce: TimeInterval = 0.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: Theme.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        // Divider against the source pane on the left.
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        // Colours are baked into the attributed string, so it must be rebuilt.
        if let source = lastSource {
            lastSource = nil
            update(source: source, immediately: true)
        }
    }

    /// Re-render `source`. Coalesces bursts of keystrokes unless `immediately`.
    func update(source: String, immediately: Bool = false) {
        guard source != lastSource else { return }
        pending?.cancel()
        renderGeneration += 1
        let generation = renderGeneration

        let apply = { [weak self] in
            guard let self, self.renderGeneration == generation else { return }
            self.pending = nil
            self.lastSource = source
            let rendered = MarkdownRenderer.render(source)
            // Preserve the scroll position: re-rendering replaces the whole
            // string, which would otherwise jump the reader back to the top on
            // every keystroke.
            let offset = self.scrollView.contentView.bounds.origin
            self.textView.textStorage?.setAttributedString(rendered)
            self.textView.scroll(offset)
        }

        if immediately {
            apply()
            return
        }
        let work = DispatchWorkItem(block: apply)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func cancelPendingUpdate() {
        renderGeneration += 1
        pending?.cancel()
        pending = nil
    }

    /// Drop both retained copies of a rendered document. A hidden preview can
    /// always be rebuilt from its document when shown again.
    func clearContent() {
        cancelPendingUpdate()
        lastSource = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    var retainedSourceLengthForTesting: Int { lastSource?.utf16.count ?? 0 }
    var renderedLengthForTesting: Int { textView.textStorage?.length ?? 0 }
}

/// Draws the decorations that can't be expressed as text attributes: the left
/// bar beside block quotes and the horizontal rule for `---`.
private final class MarkdownTextView: NSTextView {
    /// Code-block bands, drawn before `super.draw` so they land *under* the
    /// glyphs. This can't go in `drawBackground(in:)` — that is only invoked
    /// when `drawsBackground` is true, and this view is transparent.
    private func drawCodeBands() {
        guard let layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return }

        let inset = textContainerInset
        storage.enumerateAttribute(.codeBlock,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.y += inset.height
            // Full width: a glyph-width fill leaves every line a different
            // length, which reads as ragged stripes rather than one block.
            box.origin.x = inset.width
            box.size.width = max(0, bounds.width - inset.width * 2)
            box = box.insetBy(dx: 0, dy: -4)
            Theme.lineHighlight.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCodeBands()
        super.draw(dirtyRect)
        guard let layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return }

        let inset = textContainerInset
        let full = NSRange(location: 0, length: storage.length)

        storage.enumerateAttribute(.quoteLevel, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += inset.width
            box.origin.y += inset.height
            Theme.border.setFill()
            NSRect(x: inset.width + 8, y: box.minY, width: 3, height: box.height).fill()
        }

        storage.enumerateAttribute(.thematicBreak, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += inset.width
            box.origin.y += inset.height
            Theme.border.setFill()
            NSRect(x: inset.width, y: box.midY,
                   width: bounds.width - inset.width * 2, height: 1).fill()
        }
    }
}

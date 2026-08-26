import AppKit

/// In-file find bar. Uses the same styled input as the project search panel
/// (no system focus ring), plus match count, prev/next and close.
final class FindBarView: FlatView {
    var onClose: (() -> Void)?

    private let input = SearchInputView()
    private let countLabel = NSTextField(labelWithString: "")
    private weak var textView: PuzzleTextView?

    private var matches: [NSRange] = []
    private var current = -1

    /// Re-read the theme colour captured when the bar was built.
    func refreshAppearance() {
        fillColor = Theme.barBackground
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.barBackground
        bottomBorder = true

        input.placeholder = "Find in file…"
        input.translatesAutoresizingMaskIntoConstraints = false
        input.onChange = { [weak self] text, options in self?.recompute(text, options) }
        input.onSubmit = { [weak self] _, _ in self?.step(1) }
        input.onCancel = { [weak self] in self?.onClose?() }

        countLabel.font = Theme.uiFont(10.5)
        countLabel.textColor = Theme.dimText
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let prev = iconButton("chevron.up", #selector(goPrev))
        let next = iconButton("chevron.down", #selector(goNext))
        let close = iconButton("xmark", #selector(closeBar))

        let controls = NSStackView(views: [countLabel, prev, next, close])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false

        addSubview(input)
        addSubview(controls)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = Theme.dimText
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    // MARK: - API

    func attach(to textView: PuzzleTextView) {
        self.textView = textView
        recompute(input.stringValue, input.options)
    }

    /// Set the query programmatically and run it.
    func setQuery(_ text: String) {
        input.stringValue = text
        recompute(text, input.options)
    }

    func focus() {
        // Seed from the selection, like a native find bar.
        if let tv = textView, tv.selectedRange().length > 0,
           let text = (tv.string as NSString?)?.substring(with: tv.selectedRange()),
           !text.contains("\n") {
            input.stringValue = text
            recompute(text, input.options)
        }
        input.focus()
    }

    func refreshFonts() {
        input.refreshFonts()
        countLabel.font = Theme.uiFont(10.5)
    }

    // MARK: - Matching

    private func recompute(_ query: String, _ options: SearchOptions) {
        matches = []
        current = -1
        defer { updateCount(); highlight() }
        guard let tv = textView else { return }
        guard !query.isEmpty else {
            // The last one-character query leaves that match selected by the
            // editor. Once the query is empty it is no longer a result, so
            // collapse the selection as well as clearing the painted ranges.
            let selection = tv.selectedRange()
            if selection.length > 0 {
                tv.setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
            }
            return
        }
        let haystack = tv.string as NSString

        if options.regex {
            var flags: NSRegularExpression.Options = []
            if !options.caseSensitive { flags.insert(.caseInsensitive) }
            let pattern = options.wholeWord ? "\\b(?:\(query))\\b" : query
            guard let re = try? NSRegularExpression(pattern: pattern, options: flags) else { return }
            re.enumerateMatches(
                in: haystack as String,
                range: NSRange(location: 0, length: haystack.length)
            ) { m, _, _ in
                guard let r = m?.range, r.length > 0 else { return }
                matches.append(r)
            }
        } else {
            var opts: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            opts.insert(.literal)
            var searchStart = 0
            while searchStart < haystack.length {
                let found = haystack.range(of: query, options: opts,
                                           range: NSRange(location: searchStart,
                                                          length: haystack.length - searchStart))
                guard found.location != NSNotFound else { break }
                if !options.wholeWord || isWholeWord(found, in: haystack) {
                    matches.append(found)
                }
                searchStart = found.location + max(1, found.length)
            }
        }
        if !matches.isEmpty {
            // Start from the match nearest the caret.
            let caret = tv.selectedRange().location
            current = matches.firstIndex { $0.location >= caret } ?? 0
            select(current)
        }
    }

    private func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWordChar(_ i: Int) -> Bool {
            guard i >= 0, i < text.length else { return false }
            guard let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return letters.contains(scalar)
        }
        return !isWordChar(range.location - 1) && !isWordChar(NSMaxRange(range))
    }

    @objc private func goNext() { step(1) }
    @objc private func goPrev() { step(-1) }
    @objc private func closeBar() { onClose?() }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
        select(current)
        updateCount()
    }

    private func select(_ index: Int) {
        guard let tv = textView, matches.indices.contains(index) else { return }
        tv.setSelectedRange(matches[index])
        tv.scrollRangeToVisible(matches[index])
        highlight()
    }

    /// Hand the ranges to the text view, which draws them at glyph height above
    /// the current-line band. Assigning replaces the previous set outright, so
    /// stale highlights from an earlier query can't linger.
    private func highlight() {
        textView?.searchMatches = matches
        textView?.currentMatchIndex = matches.isEmpty ? nil : current
    }

    func clearHighlights() {
        matches.removeAll(keepingCapacity: false)
        current = -1
        textView?.searchMatches = []
        textView?.currentMatchIndex = nil
        countLabel.stringValue = ""
    }

    private func updateCount() {
        if matches.isEmpty {
            countLabel.stringValue = input.stringValue.isEmpty ? "" : "No results"
        } else {
            countLabel.stringValue = "\(current + 1) of \(matches.count)"
        }
    }

    var retainedMatchCountForTesting: Int { matches.count }
}

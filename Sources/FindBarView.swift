import AppKit

/// In-file find bar. Uses the same styled input as the project search panel
/// (no system focus ring), plus match count, prev/next and close.
final class FindBarView: FlatView {
    struct State {
        var isVisible = false
        var query = ""
        var options = SearchOptions()
        var replacement = ""
        var isReplacing = false
        var currentRange: NSRange?
    }
    var onClose: (() -> Void)?
    /// The bar grew or shrank a row; the pane re-lays its content.
    var onHeightChanged: (() -> Void)?

    private let input = SearchInputView()
    private let countLabel = NSTextField(labelWithString: "")
    private let replaceInput = NSTextField()
    private let replaceRow = NSView()
    private let replaceToggle = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private weak var textView: PuzzleTextView?

    private var matches: [NSRange] = []
    private var current = -1
    /// Matches found, including the ones past `maxRetainedMatches`.
    private var totalMatches = 0
    /// A single letter in a large file matches tens of thousands of times, and
    /// every one of them is a range held for as long as the query stands. Past
    /// this the count keeps counting but the ranges are not kept.
    static let maxRetainedMatches = 20_000

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
        input.onNavigate = { [weak self] delta in self?.step(delta) }
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

        // The disclosure sits left of the query, where the replace row appears.
        replaceToggle.image = NSImage(systemSymbolName: "chevron.right",
                                      accessibilityDescription: "Toggle replace")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        replaceToggle.isBordered = false
        replaceToggle.bezelStyle = .regularSquare
        replaceToggle.contentTintColor = Theme.dimText
        replaceToggle.toolTip = "Replace"
        replaceToggle.setAccessibilityLabel("Toggle replace")
        replaceToggle.target = self
        replaceToggle.action = #selector(toggleReplace)
        replaceToggle.translatesAutoresizingMaskIntoConstraints = false
        replaceToggle.widthAnchor.constraint(equalToConstant: 18).isActive = true

        replaceInput.placeholderString = "Replace with…"
        replaceInput.font = Theme.uiFont(12)
        replaceInput.textColor = Theme.foreground
        replaceInput.backgroundColor = Theme.inputBackground
        replaceInput.isBordered = false
        replaceInput.focusRingType = .none
        replaceInput.drawsBackground = true
        replaceInput.translatesAutoresizingMaskIntoConstraints = false

        let replaceOne = textButton("Replace", #selector(replaceCurrent))
        let replaceEvery = textButton("All", #selector(replaceAll))
        let replaceControls = NSStackView(views: [replaceOne, replaceEvery])
        replaceControls.orientation = .horizontal
        replaceControls.spacing = 6
        replaceControls.translatesAutoresizingMaskIntoConstraints = false

        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        replaceRow.isHidden = true
        replaceRow.addSubview(replaceInput)
        replaceRow.addSubview(replaceControls)

        addSubview(replaceToggle)
        addSubview(input)
        addSubview(controls)
        addSubview(replaceRow)
        heightConstraint = heightAnchor.constraint(equalToConstant: 42)
        NSLayoutConstraint.activate([
            heightConstraint,
            replaceToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            // Centred on the query field, not pinned a fixed distance from the
            // top: the button's own height comes from its image, so the offset
            // that happened to line up at one size did not at another.
            replaceToggle.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: replaceToggle.trailingAnchor, constant: 4),
            input.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            input.heightAnchor.constraint(equalToConstant: 30),
            input.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),

            replaceRow.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 4),
            replaceRow.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            replaceRow.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            replaceRow.heightAnchor.constraint(equalToConstant: 28),

            replaceInput.leadingAnchor.constraint(equalTo: replaceRow.leadingAnchor, constant: 6),
            replaceInput.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),
            replaceInput.trailingAnchor.constraint(
                equalTo: replaceControls.leadingAnchor, constant: -8),
            replaceControls.trailingAnchor.constraint(equalTo: replaceRow.trailingAnchor),
            replaceControls.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),
        ])
    }

    private func textButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Theme.uiFont(10.5)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
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

    var state: State {
        State(isVisible: !isHidden, query: input.stringValue, options: input.options,
              replacement: replaceInput.stringValue, isReplacing: !replaceRow.isHidden,
              currentRange: matches.indices.contains(current) ? matches[current] : nil)
    }

    var hasKeyboardFocus: Bool {
        input.hasKeyboardFocus || replaceInput.currentEditor() != nil
    }

    func restore(_ state: State, to textView: PuzzleTextView) {
        clearHighlights()
        self.textView = textView
        input.stringValue = state.query
        input.setOptions(state.options, notify: false)
        replaceInput.stringValue = state.replacement
        setReplaceVisible(state.isReplacing, focus: false)
        isHidden = !state.isVisible
        if state.isVisible {
            recompute(state.query, state.options, preferredRange: state.currentRange, reveal: false)
        }
    }

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
        input.focus()
    }

    func refreshFonts() {
        input.refreshFonts()
        countLabel.font = Theme.uiFont(10.5)
        replaceInput.font = Theme.uiFont(12)
        replaceInput.backgroundColor = Theme.inputBackground
        replaceInput.textColor = Theme.foreground
    }

    // MARK: - Replace

    /// Replacement text for `range`, expanding $1-style references when the
    /// query is a regular expression so a capture can be reused.
    func replacementText(for range: NSRange, with template: String,
                         query: String, options: SearchOptions) -> String {
        guard options.regex, let textView else { return template }
        var flags: NSRegularExpression.Options = []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        let pattern = options.wholeWord ? "\\b(?:\(query))\\b" : query
        guard let expression = try? NSRegularExpression(pattern: pattern, options: flags)
        else { return template }
        let haystack = textView.string as NSString
        guard let match = expression.firstMatch(in: haystack as String, range: range)
        else { return template }
        return expression.replacementString(for: match, in: haystack as String,
                                            offset: 0, template: template)
    }

    /// Replace the match the user is looking at, then move to the next one.
    @objc private func replaceCurrent() {
        guard let textView, current >= 0, current < matches.count else { return }
        // Each replacement is its own ⌘Z, never merged with the typing or the
        // replacement before it. The explicit group is what guarantees that:
        // NSTextView otherwise groups everything in one pass of the run loop.
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        let range = matches[current]
        let text = replacementText(for: range, with: replaceInput.stringValue,
                                   query: input.stringValue, options: input.options)
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        // The document changed under the match list, so rebuild it and keep the
        // caret where the replacement ended.
        let caret = NSRange(location: range.location + (text as NSString).length, length: 0)
        textView.setSelectedRange(caret)
        recompute(input.stringValue, input.options)
        step(1)
    }

    /// Replace every match as one edit, so a single ⌘Z puts them all back.
    /// Building the whole new text and swapping it in once is what makes that
    /// true: replacing range by range registers an undo step per match.
    @objc private func replaceAll() {
        guard let textView, !matches.isEmpty else { return }
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        let template = replaceInput.stringValue
        let query = input.stringValue
        let options = input.options
        let result = NSMutableString(string: textView.string)
        // Back to front, so each range still addresses the same text.
        for range in matches.reversed() {
            let text = replacementText(for: range, with: template,
                                       query: query, options: options)
            result.replaceCharacters(in: range, with: text)
        }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        let replacement = result as String
        guard textView.shouldChangeText(in: full, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: full, with: replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        recompute(query, options)
    }

    /// Show or hide the replace row. Hidden by default: most finds never
    /// replace, and the bar should not cost two rows of the editor until asked.
    @objc func toggleReplace() {
        setReplaceVisible(replaceRow.isHidden)
    }

    func setReplaceVisible(_ visible: Bool, focus: Bool = true) {
        guard replaceRow.isHidden == visible else { return }
        replaceRow.isHidden = !visible
        heightConstraint.constant = visible ? 76 : 42
        replaceToggle.image = NSImage(
            systemSymbolName: visible ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Toggle replace")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        onHeightChanged?()
        if visible && focus { window?.makeFirstResponder(replaceInput) }
    }

    /// One row for find, two when replace is showing.
    var preferredHeight: CGFloat { replaceRow.isHidden ? 42 : 76 }

    var isReplaceVisibleForTesting: Bool { !replaceRow.isHidden }
    /// Frames of the two things that have to line up on the query row.
    var rowAlignmentForTesting: (toggle: NSRect, input: NSRect) {
        (replaceToggle.frame, input.frame)
    }
    var queryInputForTesting: SearchInputView { input }
    func setReplacementForTesting(_ text: String) { replaceInput.stringValue = text }
    func setOptionsForTesting(_ options: SearchOptions) {
        input.setOptions(options)
        recompute(input.stringValue, options)
    }
    func replaceCurrentForTesting() { replaceCurrent() }
    func replaceAllForTesting() { replaceAll() }

    // MARK: - Matching

    private func recompute(_ query: String, _ options: SearchOptions,
                           preferredRange: NSRange? = nil, reveal: Bool = true) {
        matches = []
        totalMatches = 0
        current = -1
        defer { updateCount(); highlight() }
        guard let tv = textView else { return }
        guard !query.isEmpty else {
            // The last one-character query leaves that match selected by the
            // editor. Once the query is empty it is no longer a result, so
            // collapse the selection as well as clearing the painted ranges.
            let selection = tv.selectedRange()
            if reveal && selection.length > 0 {
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
            ) { m, _, stop in
                guard let r = m?.range, r.length > 0 else { return }
                totalMatches += 1
                guard matches.count < Self.maxRetainedMatches else { return }
                matches.append(r)
                _ = stop
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
                    totalMatches += 1
                    if matches.count < Self.maxRetainedMatches { matches.append(found) }
                }
                searchStart = found.location + max(1, found.length)
            }
        }
        // A result inside a collapsed block is opened rather than marked in
        // place: folded text has no glyphs to underline, and a result nobody
        // can see is not a result.
        tv.revealFolds(covering: matches)
        if !matches.isEmpty {
            // Start from the match nearest the caret.
            let caret = tv.selectedRange().location
            current = preferredRange.flatMap { matches.firstIndex(of: $0) }
                ?? matches.firstIndex { $0.location >= caret } ?? 0
            if reveal { select(current) }
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
        // While the bar is on screen the selection stays put. AppKit paints an
        // inactive selection in washed-out grey *over* the match highlight, so
        // seeding a query from ⌘F used to grey out the very match it found.
        // The highlight marks the current match; `finish()` moves the caret
        // there when the bar closes.
        if isHidden, tv.window?.firstResponder === tv {
            tv.setSelectedRange(matches[index])
        }
        tv.scrollRangeToVisible(matches[index])
        highlight()
    }

    /// Leave the caret on the match the user stopped at, so editing continues
    /// from there once the bar is gone.
    func finish() {
        guard let textView, matches.indices.contains(current) else { return }
        textView.setSelectedRange(matches[current])
    }

    /// Hand the ranges to the text view, which draws them at glyph height above
    /// the current-line band. Assigning replaces the previous set outright, so
    /// stale highlights from an earlier query can't linger.
    private func highlight() {
        textView?.searchMatches = matches
        textView?.currentMatchIndex = matches.isEmpty ? nil : current
        textView?.searchResultLineLocation = matches.indices.contains(current)
            ? matches[current].location : nil
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func clearHighlights() {
        matches.removeAll(keepingCapacity: false)
        totalMatches = 0
        current = -1
        textView?.searchMatches = []
        textView?.currentMatchIndex = nil
        textView?.searchResultLineLocation = nil
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        countLabel.stringValue = ""
    }

    private func updateCount() {
        if matches.isEmpty {
            countLabel.stringValue = input.stringValue.isEmpty ? "" : "No results"
        } else if totalMatches > matches.count {
            // Say so rather than reporting the cap as the truth.
            countLabel.stringValue = "\(current + 1) of \(matches.count) (\(totalMatches) found)"
        } else {
            countLabel.stringValue = "\(current + 1) of \(matches.count)"
        }
    }

    var retainedMatchCountForTesting: Int { matches.count }
    var totalMatchCountForTesting: Int { totalMatches }
}

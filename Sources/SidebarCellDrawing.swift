import AppKit

/// What a sidebar row draws in its icon slot: a Material Icon Theme icon, which
/// brings its own colours, or the tinted SF Symbol Puzzle falls back to when the
/// icon resources are unavailable.
enum SidebarIcon {
    case material(String)
    case symbol(NSImage?, NSColor)

    /// The icon for a file, by name — `package.json` and `Dockerfile` are their
    /// own icons, not just "json" and "text".
    static func file(_ url: URL) -> SidebarIcon {
        if let name = FileIcons.fileIconName(for: url.lastPathComponent) {
            return .material(name)
        }
        return .symbol(Theme.symbol(FileTreeViewController.iconName(for: url.pathExtension)),
                       Theme.dimText)
    }

    /// The icon for a folder, which also depends on whether it is open.
    static func folder(_ url: URL, expanded: Bool) -> SidebarIcon {
        if let name = FileIcons.folderIconName(for: url.lastPathComponent, expanded: expanded) {
            return .material(name)
        }
        return .symbol(Theme.symbol(expanded ? "folder.fill" : "folder"),
                       expanded ? Theme.blue : Theme.folderClosed)
    }

    /// The placeholder icon for a row being named for the first time.
    static func newItem(folder: Bool) -> SidebarIcon {
        if folder {
            return FileIcons.folderIconName(for: "", expanded: false).map(SidebarIcon.material)
                ?? .symbol(Theme.symbol("folder"), Theme.folderClosed)
        }
        return FileIcons.fileIconName(for: "").map(SidebarIcon.material)
            ?? .symbol(Theme.symbol("doc.text"), Theme.dimText)
    }
}

/// Lightweight drawing shared by the high-density sidebar rows. The table and
/// outline views remain native AppKit controls; only static icon/text content is
/// painted directly instead of allocating several child views and constraints
/// for every visible row.
enum SidebarCellDrawing {
    /// Baseline whose cap-height is optically centered in `rect`. Use the same
    /// value for adjacent labels with different font sizes so their glyphs sit
    /// on one line instead of each label being centered independently.
    static func centeredBaseline(for font: NSFont, in rect: NSRect) -> CGFloat {
        // These helpers assume a flipped view, which every drawn view in Puzzle
        // is; an unflipped host lands its text somewhere else entirely.
        //
        // Rounded to a half point: a whole device pixel on a 2x display.
        // Flooring biased every label up to a full point above the centre,
        // which showed up against the traffic lights in the title band.
        ((rect.midY + font.capHeight / 2) * 2).rounded() / 2
    }

    static func text(_ string: String, font: NSFont, color: NSColor,
                     baseline: CGFloat, in rect: NSRect,
                     lineBreak: NSLineBreakMode = .byTruncatingTail,
                     alignment: NSTextAlignment = .left) {
        guard rect.width > 0, rect.height > 0, !string.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let lineRect = NSRect(x: rect.minX,
                              y: floor(baseline - font.ascender),
                              width: rect.width,
                              height: ceil(font.ascender - font.descender + font.leading) + 2)
        (string as NSString).draw(
            with: lineRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes)
    }

    static func text(_ string: String, font: NSFont, color: NSColor,
                     in rect: NSRect,
                     lineBreak: NSLineBreakMode = .byTruncatingTail,
                     alignment: NSTextAlignment = .left) {
        text(string, font: font, color: color,
             baseline: centeredBaseline(for: font, in: rect), in: rect,
             lineBreak: lineBreak, alignment: alignment)
    }

    /// Vertical layout for a row that stacks a name over a line of metadata.
    ///
    /// Measured on ascender-to-descender rather than `boundingRectForFont`,
    /// whose box carries the font's leading: with two of those stacked, the
    /// lines drifted several points apart and the row read as two rows.
    static func twoLineBands(in rect: NSRect, primaryFont: NSFont, secondaryFont: NSFont,
                             gap: CGFloat = 1) -> (primary: NSRect, secondary: NSRect) {
        let primaryHeight = ceil(primaryFont.ascender - primaryFont.descender)
        let secondaryHeight = ceil(secondaryFont.ascender - secondaryFont.descender)
        let total = primaryHeight + gap + secondaryHeight
        let top = rect.minY + floor((rect.height - total) / 2)
        return (NSRect(x: rect.minX, y: top, width: rect.width, height: primaryHeight),
                NSRect(x: rect.minX, y: top + primaryHeight + gap,
                       width: rect.width, height: secondaryHeight))
    }

    static func attributedText(_ string: NSAttributedString, in rect: NSRect) {
        guard rect.width > 0, rect.height > 0, string.length > 0 else { return }
        let measured = string.boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let height = max(1, ceil(measured.height))
        let lineRect = NSRect(x: rect.minX,
                              y: floor(rect.midY - height / 2),
                              width: rect.width,
                              height: height + 2)
        string.draw(with: lineRect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    context: nil)
    }

    /// Draw a row's icon. Material icons carry their own colours, so they are
    /// blitted untouched; SF Symbols are templates and take a tint.
    /// A count badge: a filled circle with its digits centred, sitting on the
    /// same line as the label it follows.
    ///
    /// The circle is placed by its centre and the digits are rendered through an
    /// offscreen image, so the badge lands identically in flipped views (the
    /// sidebar cells) and unflipped ones (the activity bar). Deriving the
    /// position from a text baseline instead had it drawn on three different
    /// lines depending on the host.
    enum Badge {
        /// Room around the digits, measured against their cap-height rather
        /// than the font's line box, which carries leading a circle does not
        /// need.
        static let horizontalPadding: CGFloat = 5
        static let verticalPadding: CGFloat = 4
        static let minimumDiameter: CGFloat = 16
        /// Gap between the label and its badge.
        static let gap: CGFloat = 6

        static func font(for labelFont: NSFont) -> NSFont {
            Theme.uiFont(max(9, labelFont.pointSize - 1.5))
        }

        /// Always a circle: the diameter is whichever of the digits' width or
        /// height needs more room, so "9" and "128" are both round.
        static func size(_ value: String, labelFont: NSFont) -> NSSize {
            guard !value.isEmpty else { return .zero }
            let badgeFont = font(for: labelFont)
            let width = ceil((value as NSString).size(withAttributes: [.font: badgeFont]).width)
            let capHeight = ceil(badgeFont.capHeight)
            let diameter = max(minimumDiameter,
                               max(width + horizontalPadding * 2,
                                   capHeight + verticalPadding * 2))
            return NSSize(width: diameter, height: diameter)
        }

        /// Centred on the label's *ink* — where its glyphs actually sit.
        ///
        /// `font.capHeight` is a nominal metric: in this UI font the drawn caps
        /// are a point taller than it claims, which left the badge visibly low
        /// against the word beside it. Measuring the label settles it.
        static func draw(_ value: String, at x: CGFloat, baseline: CGFloat,
                         labelFont: NSFont, background: NSColor, foreground: NSColor,
                         alignedWith label: String = "") {
            guard !value.isEmpty else { return }
            let size = size(value, labelFont: labelFont)
            let centreY = baseline - inkHalfHeight(of: label, font: labelFont)
            // Half points: a whole device pixel at 2x. Rounding to whole points
            // shifted the circle up to a point off the text it belongs to,
            // which is exactly what "not quite centred" looked like.
            let top = ((centreY - size.height / 2) * 2).rounded() / 2
            let rect = NSRect(x: (x * 2).rounded() / 2, y: top,
                              width: size.width, height: size.height)
            image(value, labelFont: labelFont, background: background,
                  foreground: foreground)?.draw(in: rect)
        }

        /// Half the height of the label's drawn glyphs, measured from its
        /// baseline. Falls back to the nominal cap-height when there is no
        /// context to measure in.
        private static func inkHalfHeight(of label: String, font: NSFont) -> CGFloat {
            guard !label.isEmpty else { return font.capHeight / 2 }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: label, attributes: [.font: font]))
            // Glyph path bounds, which are relative to the baseline and do not
            // depend on wherever the context's text position happens to be —
            // `CTLineGetImageBounds` does, and using it put the badge ten points
            // out. Measuring beats `font.capHeight`, a nominal figure that in
            // this UI font sits a point below where the caps are actually drawn.
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard ink.height > 0 else { return font.capHeight / 2 }
            return (ink.minY + ink.maxY) / 2
        }

        /// The badge as an image: drawn in its own flipped space, so the digits
        /// are centred by construction and the result composites the same way
        /// whatever the host view does.
        static func image(_ value: String, labelFont: NSFont,
                          background: NSColor, foreground: NSColor) -> NSImage? {
            guard !value.isEmpty else { return nil }
            let size = size(value, labelFont: labelFont)
            let badgeFont = font(for: labelFont)
            return NSImage(size: size, flipped: true) { rect in
                background.setFill()
                NSBezierPath(ovalIn: rect).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: badgeFont, .foregroundColor: foreground,
                ]
                let text = value as NSString
                // Centre the digits on their ink, not on the line box: the box
                // carries ascender and descender room the digits never use.
                let measured = text.size(withAttributes: attributes)
                let capHeight = badgeFont.capHeight
                // `draw(at:)` puts the line box's top-left at the point, so the
                // cap sits `ascender - capHeight` below it. Rounded to a half
                // point, which is a whole device pixel at 2x.
                let origin = NSPoint(
                    x: ((rect.midX - measured.width / 2) * 2).rounded() / 2,
                    y: ((rect.midY - badgeFont.ascender + capHeight / 2) * 2).rounded() / 2)
                text.draw(at: origin, withAttributes: attributes)
                return true
            }
        }
    }

    /// A label with its count badge as one line of text.
    ///
    /// Placing the badge by arithmetic against the label's baseline never quite
    /// landed: the drawn baseline is not the requested one (AppKit adds the
    /// font's leading), and `capHeight` is a nominal figure this UI font does
    /// not honour. As an attachment in the same line, the two share a baseline
    /// by construction and there is nothing left to get wrong.
    static func labelWithBadge(_ label: String, badge: String, font: NSFont,
                               colour: NSColor, badgeBackground: NSColor,
                               badgeForeground: NSColor,
                               alignment: NSTextAlignment = .left,
                               lineBreak: NSLineBreakMode = .byTruncatingTail)
        -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour, .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: label, attributes: attributes)
        guard !badge.isEmpty,
              let image = Badge.image(badge, labelFont: font,
                                      background: badgeBackground,
                                      foreground: badgeForeground) else { return result }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centred on the cap-height, measured from the baseline the line itself
        // establishes.
        let size = image.size
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2,
                                   width: size.width, height: size.height)
        result.append(NSAttributedString(string: " ", attributes: attributes))
        let badgeRun = NSMutableAttributedString(attachment: attachment)
        badgeRun.addAttribute(.paragraphStyle, value: paragraph,
                              range: NSRange(location: 0, length: badgeRun.length))
        result.append(badgeRun)
        return result
    }

    static func icon(_ icon: SidebarIcon?, in rect: NSRect) {
        switch icon {
        case .material(let name):
            image(FileIcons.image(named: name, dark: true), tint: nil, in: rect)
        case .symbol(let symbol, let tint):
            image(symbol, tint: tint, in: rect)
        case nil:
            break
        }
    }

    static func image(_ image: NSImage?, tint: NSColor?, in rect: NSRect) {
        guard let image, rect.width > 0, rect.height > 0 else { return }
        // SF Symbols have different intrinsic aspect ratios (a chevron is much
        // narrower than a folder). Match NSImageView's proportional scaling;
        // stretching every symbol to the target square shifts its visual center.
        let natural = image.size
        let scale = min(rect.width / max(1, natural.width),
                        rect.height / max(1, natural.height))
        let size = NSSize(width: natural.width * scale, height: natural.height * scale)
        let fitted = NSRect(x: floor(rect.midX - size.width / 2),
                            y: floor(rect.midY - size.height / 2),
                            width: ceil(size.width), height: ceil(size.height))
        NSGraphicsContext.saveGraphicsState()
        image.draw(in: fitted, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        if let tint {
            tint.setFill()
            fitted.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draw a primary name at its natural width and let the dim secondary path
    /// consume (and truncate inside) whatever horizontal space remains.
    static func primaryAndSecondary(primary: String, primaryFont: NSFont,
                                    primaryColor: NSColor,
                                    secondary: String, secondaryFont: NSFont,
                                    secondaryColor: NSColor,
                                    in rect: NSRect, gap: CGFloat = 6,
                                    primaryLineBreak: NSLineBreakMode = .byTruncatingTail) {
        guard rect.width > 0 else { return }
        let baseline = centeredBaseline(for: primaryFont, in: rect)
        if secondary.isEmpty {
            text(primary, font: primaryFont, color: primaryColor,
                 baseline: baseline, in: rect, lineBreak: primaryLineBreak)
            return
        }

        let naturalPrimary = ceil((primary as NSString).size(
            withAttributes: [.font: primaryFont]).width)
        let primaryWidth = min(naturalPrimary, max(0, rect.width - gap))
        text(primary, font: primaryFont, color: primaryColor, baseline: baseline,
             in: NSRect(x: rect.minX, y: rect.minY,
                        width: primaryWidth, height: rect.height),
             lineBreak: primaryLineBreak)
        let secondaryX = rect.minX + primaryWidth + gap
        text(secondary, font: secondaryFont, color: secondaryColor, baseline: baseline,
             in: NSRect(x: secondaryX, y: rect.minY,
                        width: max(0, rect.maxX - secondaryX), height: rect.height),
             lineBreak: .byTruncatingHead)
    }

    /// A row that reads left to right and ends with its metadata: the leading
    /// text is what the row is about, `trailing` and `trailingPinned` are who
    /// and when. All three sit on the leading font's baseline, so a smaller
    /// metadata font still shares the line.
    ///
    /// Space is given out from the right: `trailingPinned` (the timestamp) keeps
    /// its natural width, `trailing` (the name) takes what is left of the
    /// metadata's share and truncates, and the leading text gets the rest. The
    /// order matters — letting the pair truncate as one string ate the name
    /// whole and left a dangling ellipsis in front of the date.
    static func leadingAndTrailing(leading: String, leadingFont: NSFont, leadingColor: NSColor,
                                   trailing: String, trailingFont: NSFont,
                                   trailingColor: NSColor,
                                   trailingPinned: String = "",
                                   in rect: NSRect, gap: CGFloat = 8,
                                   trailingShare: CGFloat = 0.6,
                                   leadingLineBreak: NSLineBreakMode = .byTruncatingTail) {
        guard rect.width > 0, rect.height > 0 else { return }
        let baseline = centeredBaseline(for: leadingFont, in: rect)
        func width(_ string: String) -> CGFloat {
            // A point of slack: the measured advance rounds a hair under what
            // is actually drawn, which clipped the last digit of a timestamp.
            ceil((string as NSString).size(withAttributes: [.font: trailingFont]).width) + 2
        }
        let budget = floor(rect.width * trailingShare)
        var metadataX = rect.maxX

        if !trailingPinned.isEmpty {
            let pinnedWidth = min(width(trailingPinned), budget)
            let pinned = NSRect(x: rect.maxX - pinnedWidth, y: rect.minY,
                                width: pinnedWidth, height: rect.height)
            text(trailingPinned, font: trailingFont, color: trailingColor, baseline: baseline,
                 in: pinned, lineBreak: .byClipping, alignment: .right)
            metadataX = pinned.minX
        }
        if !trailing.isEmpty {
            // The gap belongs between the name and the timestamp, not inside
            // the name's own box — right-aligned text would have pushed it to
            // the wrong side and run the two together.
            let separation = trailingPinned.isEmpty ? 0 : gap
            let remaining = max(0, budget - (rect.maxX - metadataX) - separation)
            let nameWidth = min(width(trailing), remaining)
            let name = NSRect(x: metadataX - separation - nameWidth, y: rect.minY,
                              width: nameWidth, height: rect.height)
            text(trailing, font: trailingFont, color: trailingColor, baseline: baseline,
                 in: name, lineBreak: .byTruncatingTail, alignment: .right)
            metadataX = name.minX
        }
        let leadingWidth = max(0, metadataX - gap - rect.minX)
        text(leading, font: leadingFont, color: leadingColor, baseline: baseline,
             in: NSRect(x: rect.minX, y: rect.minY,
                        width: leadingWidth, height: rect.height),
             lineBreak: leadingLineBreak)
    }
}

/// Base class that keeps the custom-drawn rows useful to VoiceOver and updates
/// their dynamic colors immediately when the effective appearance changes.
class DrawnSidebarCell: NSTableCellView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func exposeToAccessibility(_ label: String) {
        setAccessibilityLabel(label)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

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
        // Rounded to a half point — a whole device pixel on a 2x display.
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
    static func icon(_ icon: SidebarIcon?, in rect: NSRect) {
        switch icon {
        case .material(let name):
            image(FileIcons.image(named: name, dark: Theme.isDark()), tint: nil, in: rect)
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

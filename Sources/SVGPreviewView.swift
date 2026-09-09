import AppKit

/// The picture an SVG describes, drawn above the source that describes it.
///
/// Two panes when the buffer is a diff — what Git has on the left, what the
/// working tree has on the right — and one for an ordinary file.
///
/// Nothing here reads the file: the caller hands over the bytes it wants drawn,
/// which for an open file is the buffer rather than the disk, so the picture
/// follows the typing.
final class SVGPreviewView: FlatView {
    struct Pane {
        let title: String?
        let image: NSImage?
        /// What the picture is: its size in the document's own units, and what
        /// the source it came from weighs.
        let caption: String?
        /// Why there is no picture, or why the one shown is not current.
        let note: String?
    }

    private var panes: [Pane] = []

    /// Space around and between the pictures.
    private static let padding: CGFloat = 12
    private static let titleHeight: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ panes: [Pane]) {
        self.panes = panes
        needsDisplay = true
    }

    func clear() {
        panes = []
        needsDisplay = true
    }

    /// Render SVG source. Nil when the text does not describe a picture — a
    /// half-typed tag, a file that is not SVG at all.
    static func render(_ text: String) -> NSImage? {
        render(Data(text.utf8))
    }

    /// The line under a picture: its size in the document's own units, and the
    /// weight of the source it was drawn from. `name` is carried for a file,
    /// whose tab shows one picture; the two sides of a diff share a name and
    /// leave it out.
    static func caption(name: String?, image: NSImage?, bytes: Int) -> String {
        var parts: [String] = []
        if let name { parts.append(name) }
        if let image {
            parts.append("\(trimmed(image.size.width)) × \(trimmed(image.size.height))")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        return parts.joined(separator: "  ·  ")
    }

    /// `120` rather than `120.0`, and `4.5` kept: an SVG's units are its own.
    private static func trimmed(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", Double(value))
    }

    static func render(_ data: Data?) -> NSImage? {
        guard let data, !data.isEmpty, let image = NSImage(data: data),
              !image.representations.isEmpty,
              image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else { return nil }
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The seam between the picture and the source under it. The view is
        // unflipped, so its own bottom edge is the one that meets the text.
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        guard !panes.isEmpty else { return }
        let padding = Self.padding
        let width = (bounds.width - padding * CGFloat(panes.count + 1)) / CGFloat(panes.count)
        guard width > 1 else { return }
        for (index, pane) in panes.enumerated() {
            let x = padding + (width + padding) * CGFloat(index)
            draw(pane, in: NSRect(x: x, y: padding, width: width,
                                  height: max(1, bounds.height - padding * 2)))
            // A hairline between the two versions, so the pictures are read as
            // two rather than as one wide one.
            if index > 0 {
                Theme.border.setFill()
                NSRect(x: x - padding / 2, y: padding,
                       width: 1, height: max(1, bounds.height - padding * 2)).fill()
            }
        }
    }

    private func draw(_ pane: Pane, in rect: NSRect) {
        var content = rect
        func centred(_ text: String, at y: CGFloat, in colour: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.uiFont(10.5), .foregroundColor: colour,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: y),
                                    withAttributes: attributes)
        }
        if let title = pane.title {
            centred(title, at: rect.maxY - Self.titleHeight, in: Theme.dimText)
            content.size.height -= Self.titleHeight + 4
        }
        // Under the picture: what it is, then why it is not current. Both strips
        // come out of the space the picture is drawn in, so nothing overlaps.
        var footer = rect.minY
        if let caption = pane.caption {
            centred(caption, at: footer, in: Theme.dimText)
            footer += Self.titleHeight
            content.origin.y += Self.titleHeight
            content.size.height -= Self.titleHeight
        }
        if let note = pane.note {
            centred(note, at: footer,
                    in: pane.image == nil ? Theme.dimText : Theme.yellow)
            content.origin.y += Self.titleHeight + 2
            content.size.height -= Self.titleHeight + 2
        }
        guard let image = pane.image, content.width > 1, content.height > 1 else { return }
        let size = Self.fitted(image.size, in: content.size)
        let frame = NSRect(x: content.midX - size.width / 2,
                           y: content.midY - size.height / 2,
                           width: size.width, height: size.height)
        drawCheckerboard(in: frame)
        image.draw(in: frame)
    }

    /// Shrunk to fit and never enlarged, the rule the image preview uses: a
    /// 24pt icon blown up to fill half the pane says nothing about how it will
    /// look, and a picture at its own size can be compared with one.
    static func fitted(_ image: NSSize, in available: NSSize) -> NSSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(1, available.width / image.width, available.height / image.height)
        return NSSize(width: floor(image.width * scale), height: floor(image.height * scale))
    }

    /// The grey squares that stand in for transparency, the same ones the
    /// image preview draws: an SVG is mostly transparent, and without them a
    /// white drawing on the dark editor looks like a drawing on a white card.
    private func drawCheckerboard(in frame: NSRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        let square: CGFloat = 8
        NSColor(white: 0.22, alpha: 1).setFill()
        frame.fill()
        NSColor(white: 0.27, alpha: 1).setFill()
        var row = 0
        var y = frame.minY
        while y < frame.maxY {
            var x = frame.minX + (row % 2 == 0 ? 0 : square)
            while x < frame.maxX {
                NSRect(x: x, y: y, width: min(square, frame.maxX - x),
                       height: min(square, frame.maxY - y)).fill()
                x += square * 2
            }
            y += square
            row += 1
        }
    }

    var paneCountForTesting: Int { panes.count }
    var paneTitlesForTesting: [String?] { panes.map(\.title) }
    var paneCaptionsForTesting: [String?] { panes.map(\.caption) }
    var paneNotesForTesting: [String?] { panes.map(\.note) }
    var paneHasImageForTesting: [Bool] { panes.map { $0.image != nil } }
}

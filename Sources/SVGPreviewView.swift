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
    private var pictures: [ImagePreviewView] = []

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
        if pictures.count != panes.count {
            pictures.forEach { $0.removeFromSuperview() }
            pictures = panes.map { _ in
                let preview = ImagePreviewView()
                preview.imagePadding = 4
                addSubview(preview)
                return preview
            }
        }
        for (pane, picture) in zip(panes, pictures) {
            picture.updateVectorImage(pane.image, caption: pane.caption ?? "")
        }
        needsLayout = true
        needsDisplay = true
    }

    func clear() { show([]) }

    func refreshFonts() {
        fillColor = Theme.editorBackground
        pictures.forEach { $0.refreshFonts() }
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
        for (index, pane) in panes.enumerated() {
            let rect = paneRect(at: index)
            if index > 0 {
                Theme.border.setFill()
                NSRect(x: rect.minX - Self.padding / 2, y: rect.minY,
                       width: 1, height: rect.height).fill()
            }
            if let title = pane.title {
                drawLabel(title, in: rect, at: rect.maxY - Self.titleHeight, color: Theme.dimText)
            }
            if let note = pane.note {
                drawLabel(note, in: rect, at: rect.minY,
                          color: pane.image == nil ? Theme.dimText : Theme.yellow)
            }
        }
    }

    override func layout() {
        super.layout()
        for (index, picture) in pictures.enumerated() {
            var rect = paneRect(at: index)
            let titleSpace = panes[index].title == nil ? 0 : Self.titleHeight + 4
            let noteSpace = panes[index].note == nil ? 0 : Self.titleHeight + 2
            rect.origin.y += noteSpace
            rect.size.height = max(0, rect.height - noteSpace - titleSpace)
            picture.frame = rect
        }
    }

    private func paneRect(at index: Int) -> NSRect {
        let padding = Self.padding
        let width = max(0, (bounds.width - padding * CGFloat(panes.count + 1))
                        / CGFloat(panes.count))
        return NSRect(x: padding + (width + padding) * CGFloat(index), y: padding,
                      width: width, height: max(0, bounds.height - 2 * padding))
    }

    private func drawLabel(_ text: String, in rect: NSRect, at y: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: NSRect(x: rect.minX, y: y, width: rect.width,
                                           height: Self.titleHeight),
                                withAttributes: [.font: Theme.uiFont(10.5),
                                                 .foregroundColor: color,
                                                 .paragraphStyle: style])
    }

    var paneCountForTesting: Int { panes.count }
    var paneTitlesForTesting: [String?] { panes.map(\.title) }
    var paneCaptionsForTesting: [String?] { panes.map(\.caption) }
    var paneNotesForTesting: [String?] { panes.map(\.note) }
    var paneHasImageForTesting: [Bool] { panes.map { $0.image != nil } }
}

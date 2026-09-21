import AppKit

/// Compact Git ref pills shared by History rows. A row gives them only the
/// space it can spare; the returned rectangles describe exactly what was
/// painted so the following commit content can begin immediately after it.
enum GitRefLabelsDrawing {
    static let gap: CGFloat = 4
    static let horizontalPadding: CGFloat = 5
    static let height: CGFloat = 16
    static var font: NSFont { Theme.uiFont(9) }

    static func width(_ refs: [GitService.Commit.RefLabel]) -> CGFloat {
        let widths = refs.map {
            ceil(($0.name as NSString).size(withAttributes: [.font: font]).width)
                + horizontalPadding * 2
        }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
    }

    @discardableResult
    static func draw(_ refs: [GitService.Commit.RefLabel], in rect: NSRect,
                     currentColor: NSColor) -> [NSRect] {
        guard !refs.isEmpty, rect.width > 0 else { return [] }
        var drawn: [NSRect] = []
        var x = rect.minX
        for ref in refs where x < rect.maxX {
            let natural = ceil((ref.name as NSString)
                .size(withAttributes: [.font: font]).width) + horizontalPadding * 2
            let width = min(natural, rect.maxX - x)
            guard width >= horizontalPadding * 2 + 4 else { break }
            let pill = NSRect(x: x, y: floor(rect.midY - height / 2),
                              width: width, height: height)
            let color: NSColor
            switch ref.kind {
            case .localBranch: color = ref.isCurrent ? currentColor : Theme.blue
            case .remoteBranch: color = Theme.purple
            case .tag: color = Theme.yellow
            case .detachedHead: color = Theme.orange
            }
            color.withAlphaComponent(0.14).setFill()
            let path = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
            path.fill()
            color.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
            SidebarCellDrawing.text(
                ref.name, font: font, color: color,
                in: pill.insetBy(dx: horizontalPadding, dy: 0),
                lineBreak: .byTruncatingMiddle)
            drawn.append(pill)
            x = pill.maxX + gap
        }
        return drawn
    }
}

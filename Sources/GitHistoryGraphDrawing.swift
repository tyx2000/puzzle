import AppKit

/// A graph is painted with the row, not with one view or layer per edge.
/// Coordinates run top to bottom, just like DrawnSidebarCell's flipped bounds.
enum GitHistoryGraphDrawing {
    static let laneSpacing: CGFloat = 16
    static let trailingGap: CGFloat = 10

    static func columnWidth(laneCount: Int) -> CGFloat {
        laneCount > 0 ? CGFloat(laneCount) * laneSpacing + trailingGap : 0
    }

    private static func color(_ index: Int) -> NSColor {
        Theme.gitGraphColors[index % Theme.gitGraphColors.count]
    }

    private static func x(_ lane: Int, in rect: NSRect) -> CGFloat {
        rect.minX + laneSpacing / 2 + CGFloat(lane) * laneSpacing
    }

    static func draw(_ row: GitHistoryGraph.Row, in rect: NSRect) {
        guard !rect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        let center = NSPoint(x: x(row.nodeLane, in: rect), y: rect.midY)
        func circle(_ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        // Leave the node interior transparent so stripes and hover show
        // through merge dots and HEAD rings without a mismatched dark disk.
        NSGraphicsContext.saveGraphicsState()
        let trackClip = NSBezierPath(rect: rect)
        trackClip.append(circle(row.isHead ? 6 : 4.5))
        trackClip.windingRule = .evenOdd
        trackClip.addClip()
        for segment in row.segments {
            let start = NSPoint(x: x(segment.fromLane, in: rect),
                                y: rect.minY + CGFloat(segment.fromY) * rect.height)
            let end = NSPoint(x: x(segment.toLane, in: rect),
                              y: rect.minY + CGFloat(segment.toY) * rect.height)
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: start)
            if segment.fromLane == segment.toLane {
                path.line(to: end)
            } else {
                // Vertical tangents meet the adjoining rows without a kink.
                let middleY = (start.y + end.y) / 2
                path.curve(to: end,
                           controlPoint1: NSPoint(x: start.x, y: middleY),
                           controlPoint2: NSPoint(x: end.x, y: middleY))
            }
            color(segment.colorIndex).setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let nodeColor = color(row.colorIndex)
        nodeColor.setFill()
        nodeColor.setStroke()
        if row.isHead {
            let ring = circle(5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        if row.isMerge {
            let node = circle(3.2)
            node.lineWidth = 1.8
            node.stroke()
        } else {
            circle(3).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// File rows do not add a commit. They extend the tracks leaving the
    /// owning commit so expansion never visually disconnects the history.
    static func drawContinuation(_ lanes: [GitHistoryGraph.Lane], in rect: NSRect) {
        guard !rect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        for lane in lanes {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: x(lane.lane, in: rect), y: rect.minY))
            path.line(to: NSPoint(x: x(lane.lane, in: rect), y: rect.maxY))
            color(lane.colorIndex).setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

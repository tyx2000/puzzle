import AppKit

// Puzzle's app icon: a white rounded-square badge with black "Puzz" wordmark.
// Emits an .iconset which build.sh turns into AppIcon.icns.

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])   // …/AppIcon.iconset
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)

    let full = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    full.fill()

    // White rounded-square badge (macOS icon shape).
    let inset = size * 0.055
    let badge = NSBezierPath(roundedRect: full.insetBy(dx: inset, dy: inset),
                             xRadius: size * 0.225, yRadius: size * 0.225)
    NSColor.white.setFill()
    badge.fill()
    // Hairline edge so the icon still reads against a white background.
    NSColor(white: 0.82, alpha: 1).setStroke()
    badge.lineWidth = max(1, size * 0.006)
    badge.stroke()

    // "Puzz" in black SF Rounded, at natural proportions — no vertical stretch,
    // so the letterforms keep their real shape. The word is wide, so its width
    // is what sets the size; the remaining top/bottom space just centres it.
    let text = "Puzz" as NSString
    let badgeSide = size - inset * 2
    let margin = badgeSide * 0.07
    let available = badgeSide - margin * 2

    func roundedFont(ofSize pt: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: pt, weight: .bold)
        if let d = base.fontDescriptor.withDesign(.rounded),
           let f = NSFont(descriptor: d, size: pt) {
            return f
        }
        return base   // older macOS: fall back to the standard face
    }

    let probePt: CGFloat = 100
    let probe = roundedFont(ofSize: probePt)
    let probeWidth = text.size(withAttributes: [.font: probe]).width
    let font = roundedFont(ofSize: probePt * (available / probeWidth))

    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]

    // Centre on the true INK bounds, not the advance width / line box: the
    // advance carries a trailing side-bearing, which pushed the word ~10px left
    // of centre, and the line box carries leading the glyphs never use.
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text as String, attributes: attrs))
    let ink = CTLineGetImageBounds(line, NSGraphicsContext.current!.cgContext)

    // Origin that lands the ink box exactly in the middle of the canvas.
    // CTLine ink is measured from the BASELINE, but `draw(at:)` takes the
    // bottom-left of the LINE BOX — the baseline sits |descender| above that,
    // so the descender has to be added back or the word rides ~76px high.
    let origin = NSPoint(x: (size - ink.width) / 2 - ink.minX,
                         y: size / 2 - ink.midY + font.descender)
    text.draw(at: origin, withAttributes: attrs)

    image.unlockFocus()
    return image
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in specs {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("wrote \(specs.count) icon sizes to \(outDir.path)")

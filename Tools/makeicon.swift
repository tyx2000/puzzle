import AppKit

// Puzzle's app icon: the artwork in Tools/appicon.jpg, unchanged, behind the
// standard macOS rounded-square mask. Emits an .iconset which build.sh turns
// into AppIcon.icns.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: makeicon <iconset-dir> <artwork>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1])   // …/AppIcon.iconset
let artworkURL = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let artwork = NSImage(contentsOf: artworkURL) else {
    FileHandle.standardError.write(Data("makeicon: cannot read \(artworkURL.path)\n".utf8))
    exit(1)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)
    NSGraphicsContext.current?.imageInterpolation = .high

    let full = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    full.fill()

    // macOS icon shape: the artwork is inset from the canvas and its corners are
    // rounded. Everything inside the mask is the original picture, untouched —
    // scaled to fill so a square source keeps its framing.
    let inset = size * 0.055
    let badge = full.insetBy(dx: inset, dy: inset)
    let mask = NSBezierPath(roundedRect: badge,
                            xRadius: size * 0.225, yRadius: size * 0.225)
    NSGraphicsContext.saveGraphicsState()
    mask.addClip()
    let source = artwork.size
    let scale = max(badge.width / max(1, source.width), badge.height / max(1, source.height))
    let drawn = NSSize(width: source.width * scale, height: source.height * scale)
    artwork.draw(in: NSRect(x: badge.midX - drawn.width / 2,
                            y: badge.midY - drawn.height / 2,
                            width: drawn.width, height: drawn.height),
                 from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

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

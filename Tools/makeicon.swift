import AppKit

// Puzzle's app icon: a "mineral moon" — a full moon on black whose maria are
// tinted with the mineral colours (titanium blues, iron oxide oranges/reds).
// Drawn procedurally with a seeded RNG so every build is identical.

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])   // …/AppIcon.iconset
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Deterministic LCG — same icon every build.
struct RNG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFFFFFFFF) / Double(0xFFFFFFFF)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
}

func rgba(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

/// An organic blob: a circle whose radius wobbles with a few harmonics.
func blob(center: NSPoint, radius: CGFloat, wobble: CGFloat, rng: inout RNG) -> NSBezierPath {
    let p = NSBezierPath()
    let steps = 72
    let h1 = rng.range(0, .pi * 2), h2 = rng.range(0, .pi * 2), h3 = rng.range(0, .pi * 2)
    let a1 = rng.range(0.10, 0.26), a2 = rng.range(0.06, 0.18), a3 = rng.range(0.04, 0.12)
    for i in 0...steps {
        let t = Double(i) / Double(steps) * .pi * 2
        let wob = 1
            + a1 * sin(2 * t + h1)
            + a2 * sin(3 * t + h2)
            + a3 * sin(5 * t + h3)
        let r = radius * CGFloat(wob) * (1 + wobble * 0)
        let pt = NSPoint(x: center.x + r * CGFloat(cos(t)), y: center.y + r * CGFloat(sin(t)))
        if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
    }
    p.close()
    return p
}

func drawIcon(size: CGFloat) -> NSImage {
    var rng = RNG(state: 0xC0FFEE_1234)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.imageInterpolation = .high

    let full = NSRect(x: 0, y: 0, width: size, height: size)

    // Black rounded-square badge (macOS icon shape).
    let inset = size * 0.055
    let badge = NSBezierPath(roundedRect: full.insetBy(dx: inset, dy: inset),
                             xRadius: size * 0.225, yRadius: size * 0.225)
    badge.addClip()
    rgba(0x05060A).setFill()
    full.fill()

    // The moon disc — kept inside the badge so black margin shows all round.
    let R = size * 0.355
    let c = NSPoint(x: size / 2, y: size / 2)
    let discRect = NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
    let disc = NSBezierPath(ovalIn: discRect)

    NSGraphicsContext.saveGraphicsState()
    disc.addClip()

    // Base regolith with a soft light from the upper-left.
    NSGradient(colors: [rgba(0xE8E8EA), rgba(0xB9B9BE), rgba(0x8E8E95)])?
        .draw(in: discRect.insetBy(dx: -R * 0.35, dy: -R * 0.35),
              relativeCenterPosition: NSPoint(x: -0.28, y: 0.30))

    // Mineral maria — the colourful patches.
    // Mineral maria: smaller, scattered, translucent — tint rather than paint.
    let patches: [(NSPoint, CGFloat, UInt32, CGFloat)] = [
        // (unit offset from centre, radius factor, colour, alpha)
        (NSPoint(x: -0.34, y:  0.30), 0.20, 0x3D6FA8, 0.34),   // titanium blue
        (NSPoint(x: -0.10, y:  0.46), 0.15, 0x4C79AE, 0.28),
        (NSPoint(x:  0.14, y:  0.40), 0.17, 0xC8702E, 0.32),   // iron oxide orange
        (NSPoint(x:  0.36, y:  0.20), 0.16, 0xA8402F, 0.30),   // rust red
        (NSPoint(x:  0.30, y: -0.02), 0.13, 0x9B4536, 0.26),
        (NSPoint(x: -0.46, y: -0.02), 0.13, 0x2F7F86, 0.26),   // teal
        (NSPoint(x: -0.04, y:  0.10), 0.14, 0x6E5AA0, 0.24),   // violet
        (NSPoint(x:  0.26, y: -0.36), 0.17, 0x2E5F9E, 0.32),   // deep blue
        (NSPoint(x: -0.22, y: -0.34), 0.12, 0xB05A34, 0.24),   // ochre
        (NSPoint(x: -0.30, y: -0.10), 0.10, 0x8C6BAF, 0.20),
        (NSPoint(x:  0.06, y: -0.18), 0.11, 0x50607F, 0.18),
    ]
    for (offset, rf, colour, alpha) in patches {
        let centre = NSPoint(x: c.x + offset.x * R, y: c.y + offset.y * R)
        let path = blob(center: centre, radius: R * rf, wobble: 0.2, rng: &rng)
        rgba(colour, alpha).setFill()
        path.fill()
    }

    // Crater field: mostly tiny, low contrast — texture, not polka dots.
    for _ in 0..<420 {
        let ang = rng.range(0, .pi * 2)
        // sqrt keeps the distribution even across the disc area
        let dist = CGFloat(sqrt(rng.next())) * R * 0.985
        let p = NSPoint(x: c.x + dist * CGFloat(cos(ang)), y: c.y + dist * CGFloat(sin(ang)))
        // Heavily biased small: cube of a uniform makes big craters rare.
        let t = rng.next() * rng.next() * rng.next()
        let r = CGFloat(Double(size) * (0.0025 + t * 0.030))
        rgba(0x2A2A30, CGFloat(rng.range(0.04, 0.10))).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
        // Sun-lit rim on the upper-left edge only.
        rgba(0xFFFFFF, CGFloat(rng.range(0.03, 0.09))).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: p.x - r - r * 0.10, y: p.y - r + r * 0.12,
                                              width: r * 2, height: r * 2))
        rim.lineWidth = max(0.4, size * 0.0012)
        rim.stroke()
    }

    // Two bright ray craters (Tycho / Copernicus).
    for (ux, uy, rad, rays) in [(-0.10, -0.62, 0.055, 34), (-0.34, 0.10, 0.035, 22)] {
        let p = NSPoint(x: c.x + CGFloat(ux) * R, y: c.y + CGFloat(uy) * R)
        let r = R * CGFloat(rad)
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * .pi * 2 + rng.range(-0.05, 0.05)
            let len = r * CGFloat(rng.range(3.0, 9.0))
            let path = NSBezierPath()
            path.move(to: p)
            path.line(to: NSPoint(x: p.x + len * CGFloat(cos(a)), y: p.y + len * CGFloat(sin(a))))
            rgba(0xFFFFFF, CGFloat(rng.range(0.05, 0.13))).setStroke()
            path.lineWidth = max(0.6, r * CGFloat(rng.range(0.10, 0.26)))
            path.stroke()
        }
        rgba(0xFFFFFF, 0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
        rgba(0x8A8A90, 0.5).setFill()
        let inner = r * 0.55
        NSBezierPath(ovalIn: NSRect(x: p.x - inner, y: p.y - inner,
                                    width: inner * 2, height: inner * 2)).fill()
    }

    // Limb darkening: a vignette confined to the disc itself.
    let limb = NSGradient(colors: [rgba(0x000000, 0), rgba(0x000000, 0.10), rgba(0x000000, 0.62)],
                          atLocations: [0.0, 0.78, 1.0], colorSpace: .sRGB)
    limb?.draw(in: discRect, relativeCenterPosition: NSPoint(x: -0.10, y: 0.10))

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

import AppKit

// Harbor's icon: a clay sun coming up over a calm harbor. The prompt is in the sun, and its
// reflection on the water is a few lines, the way code looks from a distance. The colors are
// the application's own warm theme. Coordinates are on a 1024 grid measured from the top left.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func stroke(_ points: [NSPoint], width: CGFloat, _ paint: NSColor) {
    let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
    paint.setStroke(); path.stroke()
}
func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, _ paint: NSColor) {
    paint.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
}
func scoped(_ body: () -> Void) { NSGraphicsContext.saveGraphicsState(); body(); NSGraphicsContext.restoreGraphicsState() }

for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let grid = NSAffineTransform(); grid.translateX(by: 0, yBy: CGFloat(pixels)); grid.scaleX(by: CGFloat(pixels) / 1024, yBy: -CGFloat(pixels) / 1024); grid.concat()
    // At 16 and 32 pixels there is room for the sun, the chevron and two lines, each drawn heavier.
    let small = pixels <= 32
    let center = NSPoint(x: 512, y: small ? 556 : 542), radius: CGFloat = small ? 292 : 256, horizon: CGFloat = small ? 596 : 580
    let cream = color(0xFFFAF0), clay = color(0xC2502A)

    NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 195, yRadius: 195).addClip()
    NSGradient(starting: color(0xFFFCF6), ending: color(0xF0E2CB))!.draw(from: NSPoint(x: 0, y: 84), to: NSPoint(x: 0, y: 940), options: [])
    scoped {
        // Everything of the sun is above the waterline.
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: horizon)).addClip()
        if !small {
            color(0xF2A57C, 0.13).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 350, y: center.y - 350, width: 700, height: 700)).fill()
        }
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).addClip()
        NSGradient(starting: color(0xF3A072), ending: clay)!.draw(from: NSPoint(x: 0, y: center.y - radius), to: NSPoint(x: 0, y: horizon), options: [])
        // Morning light on the upper left of the disc.
        NSGradient(starting: color(0xFFE3C4, 0.34), ending: color(0xFFE3C4, 0))!
            .draw(fromCenter: NSPoint(x: center.x - 90, y: center.y - radius + 40), radius: 0, toCenter: NSPoint(x: center.x - 90, y: center.y - radius + 40), radius: 240, options: [])
    }
    scoped {
        let shade = NSShadow(); shade.shadowColor = color(0x8C3418, 0.30); shade.shadowBlurRadius = 14 * CGFloat(pixels) / 1024
        shade.shadowOffset = NSSize(width: 0, height: -7 * CGFloat(pixels) / 1024); shade.set()
        if small {
            stroke([NSPoint(x: 404, y: 356), NSPoint(x: 556, y: 464), NSPoint(x: 404, y: 572)], width: 84, cream)
        } else {
            stroke([NSPoint(x: 388, y: 374), NSPoint(x: 500, y: 462), NSPoint(x: 388, y: 550)], width: 54, cream)
            stroke([NSPoint(x: 546, y: 550), NSPoint(x: 644, y: 550)], width: 50, cream)
        }
    }
    if small {
        bar(x: 240, y: 656, width: 544, height: 62, clay.withAlphaComponent(0.92))
        bar(x: 350, y: 762, width: 324, height: 62, clay.withAlphaComponent(0.55))
    } else {
        bar(x: 270, y: 620, width: 484, height: 36, clay.withAlphaComponent(0.90))
        bar(x: 346, y: 688, width: 332, height: 36, clay.withAlphaComponent(0.60))
        bar(x: 420, y: 756, width: 184, height: 36, clay.withAlphaComponent(0.34))
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(name).png"))
}

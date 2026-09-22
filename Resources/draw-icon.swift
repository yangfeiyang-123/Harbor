import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024); (transform as NSAffineTransform).concat()
    let box = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 195, yRadius: 195)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.26, blue: 0.29, alpha: 1), ending: NSColor(calibratedRed: 0.025, green: 0.08, blue: 0.11, alpha: 1))!.draw(in: box, angle: -70)
    NSColor(calibratedRed: 0.30, green: 0.82, blue: 0.70, alpha: 1).setStroke()
    let prompt = NSBezierPath(); prompt.lineWidth = 64; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
    prompt.move(to: NSPoint(x: 290,y: 655)); prompt.line(to: NSPoint(x: 440,y: 510)); prompt.line(to: NSPoint(x: 290,y: 365)); prompt.stroke()
    let cursor = NSBezierPath(); cursor.lineWidth = 58; cursor.lineCapStyle = .round
    cursor.move(to: NSPoint(x: 545,y: 365)); cursor.line(to: NSPoint(x: 735,y: 365)); cursor.stroke()
    NSColor.white.withAlphaComponent(0.22).setFill()
    for x in [285, 345, 405] { NSBezierPath(ovalIn: NSRect(x: x, y: 774, width: 23, height: 23)).fill() }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(name).png"))
}

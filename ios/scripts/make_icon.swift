// Renders the AI Usage app icon (1024x1024 PNG).
// Usage: swift make_icon.swift /path/to/AppIcon.png
import AppKit

let size = 1024
guard CommandLine.arguments.count > 1 else {
    fputs("usage: make_icon.swift <out.png>\n", stderr)
    exit(1)
}
let outPath = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let s = CGFloat(size)

// Background: deep charcoal, slightly lighter at the top.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1.0),
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

// Claude sunburst in clay, upper-center.
let clay = NSColor(calibratedRed: 0.87, green: 0.48, blue: 0.34, alpha: 1.0)
clay.set()
let center = NSPoint(x: s / 2, y: s * 0.62)
let rays = 12
let outer: CGFloat = s * 0.23
let inner: CGFloat = s * 0.045
let thickness: CGFloat = s * 0.052
for i in 0..<rays {
    let angle = (CGFloat.pi * 2 * CGFloat(i)) / CGFloat(rays) - .pi / 2
    let path = NSBezierPath()
    path.lineWidth = thickness
    path.lineCapStyle = .round
    path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
    path.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
    path.stroke()
}

// Usage bar beneath: track + green fill.
let barWidth: CGFloat = s * 0.56
let barHeight: CGFloat = s * 0.072
let barRect = NSRect(x: (s - barWidth) / 2, y: s * 0.20, width: barWidth, height: barHeight)
NSColor(calibratedWhite: 1.0, alpha: 0.16).set()
NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

NSColor(calibratedRed: 0.36, green: 0.79, blue: 0.40, alpha: 1.0).set()
let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barWidth * 0.68, height: barHeight)
NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

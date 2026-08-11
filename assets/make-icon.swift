// Generates AppIcon-1024.png — the widget's own look, miniaturized:
// dark glass card, three gauge bars in the identity palette, Claude sparkle.
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Card: Apple-margin squircle, charcoal glass with a faint warm cast
let card = NSRect(x: 96, y: 96, width: 832, height: 832)
let cardPath = NSBezierPath(roundedRect: card, xRadius: 184, yRadius: 184)
NSGradient(colors: [rgb(0x2B2723), rgb(0x1B1815)])!.draw(in: cardPath, angle: -90)

// Top inner highlight (the "3D" edge the widget wears)
cardPath.addClip()
let hl = NSBezierPath(roundedRect: card.insetBy(dx: 4, dy: 4), xRadius: 180, yRadius: 180)
hl.lineWidth = 8
rgb(0xFFFFFF, 0.09).setStroke()
hl.stroke()

// Three gauge bars — session terracotta, week ochre, model sage
let barX: CGFloat = 216, barW: CGFloat = 592, barH: CGFloat = 78
let bars: [(y: CGFloat, frac: CGFloat, color: NSColor)] = [
    (602, 0.60, rgb(0xD97757)),
    (458, 0.38, rgb(0xBC8F40)),
    (314, 0.76, rgb(0x739487)),
]
for b in bars {
    let track = NSRect(x: barX, y: b.y, width: barW, height: barH)
    rgb(0xFFFFFF, 0.09).setFill()
    NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
    let fill = NSRect(x: barX, y: b.y, width: max(barH, barW * b.frac), height: barH)
    b.color.setFill()
    NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()
}

// Claude sparkle, tucked into the clear top-right corner, soft halo
let cx: CGFloat = 768, cy: CGFloat = 774, r: CGFloat = 96, rIn = r * 0.24
let glow = NSGradient(colors: [rgb(0xD97757, 0.10), rgb(0xD97757, 0.0)])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: cx - r * 1.9, y: cy - r * 1.9, width: r * 3.8, height: r * 3.8)),
          relativeCenterPosition: .zero)
let star = NSBezierPath()
let pts: [(CGFloat, CGFloat)] = (0..<8).map { i in
    let ang = CGFloat(i) * .pi / 4 + .pi / 2
    let rad = i % 2 == 0 ? r : rIn
    return (cx + cos(ang) * rad, cy + sin(ang) * rad)
}
star.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
for p in pts.dropFirst() { star.line(to: NSPoint(x: p.0, y: p.1)) }
star.close()
rgb(0xF0EEE5).setFill()
star.fill()

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")

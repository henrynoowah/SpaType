// Renders the SpaType app icon. Usage: swift scripts/make-icon.swift <out.png> [--single]
//
// A MacBook keyboard key on an aluminium tile. Like the keys on a Korean MacBook, it carries
// two legends on a diagonal: the Latin "s" top-right and the Hangul "ㄴ" bottom-left —
// the same key, two languages, which is exactly the mix-up SpaType fixes.
import AppKit

let size: CGFloat = 1024
let args = Array(CommandLine.arguments.dropFirst())
let out = args.first { !$0.hasPrefix("--") } ?? "AppIcon.png"
let showNeighbors = !args.contains("--single")   // default: zoomed-in keyboard with neighbouring keys

// MARK: Palette
let aluminiumTop = 0xE9EBEF, aluminiumBottom = 0xB4B9C1     // silver deck
let wellColor = 0x0E0F11                                     // gap around the key
let capTop = 0x2E2F33, capBottom = 0x1B1C1F                  // black keycap
let legend = 0xF2F3F5

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func font(_ names: [String], size: CGFloat, weight: NSFont.Weight) -> NSFont {
    for name in names { if let f = NSFont(name: name, size: size) { return f } }
    return .systemFont(ofSize: size, weight: weight)
}

/// Draws `text` with the top-left (or bottom-right) of its visible glyphs at `point`.
enum Anchor { case topLeft, topRight, bottomLeft, bottomRight, center }
func drawText(_ text: String, font: NSFont, color: NSColor, at point: CGPoint, anchor: Anchor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let b = str.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
    let origin: CGPoint
    switch anchor {
    case .topLeft: origin = CGPoint(x: point.x - b.minX, y: point.y - b.maxY)
    case .topRight: origin = CGPoint(x: point.x - b.maxX, y: point.y - b.maxY)
    case .bottomLeft: origin = CGPoint(x: point.x - b.minX, y: point.y - b.minY)
    case .bottomRight: origin = CGPoint(x: point.x - b.maxX, y: point.y - b.minY)
    case .center: origin = CGPoint(x: point.x - b.midX, y: point.y - b.midY)
    }
    str.draw(at: origin)
}

/// One MacBook-style key: a dark well, then a flat black cap with a soft top highlight.
func drawKey(_ rect: CGRect, radius: CGFloat, alpha: CGFloat = 1, ctx: CGContext) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    // Well (the cut-out in the aluminium deck).
    let well = rect.insetBy(dx: -rect.width * 0.035, dy: -rect.width * 0.035)
    color(wellColor).setFill()
    NSBezierPath(roundedRect: well, xRadius: radius * 1.15, yRadius: radius * 1.15).fill()

    // Cap.
    let cap = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    cap.addClip()
    NSGradient(colors: [color(capTop), color(capBottom)])!.draw(in: rect, angle: -90)
    // Backlight spill / sheen across the top edge.
    NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
        .draw(in: CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.25, width: rect.width, height: rect.height * 0.25), angle: -90)
    ctx.restoreGState()
    color(0xFFFFFF, 0.10).setStroke()
    let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5)
    edge.lineWidth = 3
    edge.stroke()
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// MARK: Tile (macOS icon grid: 824pt body, centred, ~185pt corner radius)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

ctx.saveGState()
let tileShadow = NSShadow()
tileShadow.shadowColor = color(0x000000, 0.30)
tileShadow.shadowOffset = CGSize(width: 0, height: -12)
tileShadow.shadowBlurRadius = 28
tileShadow.set()
color(aluminiumBottom).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [color(aluminiumTop), color(aluminiumBottom)])!.draw(in: tile, angle: -90)
// Faint brushed-metal streaks.
for i in stride(from: 0, to: 824, by: 6) {
    let y = tile.minY + CGFloat(i)
    color(0xFFFFFF, (i / 6) % 3 == 0 ? 0.05 : 0.0).setFill()
    NSBezierPath(rect: CGRect(x: tile.minX, y: y, width: tile.width, height: 2)).fill()
}

// MARK: Keys
let keySize: CGFloat = showNeighbors ? 440 : 520
let gap: CGFloat = showNeighbors ? 44 : 60
let key = CGRect(x: 512 - keySize / 2, y: 512 - keySize / 2, width: keySize, height: keySize)
let radius = keySize * 0.11
/// "ㄴ" sits lower than "s" is high, like the Hangul legend on a real Korean MacBook key.
let hangulBottomInset: CGFloat = 0.085

if showNeighbors {
    // Real row stagger, relative to S: the QWER row sits 0.25 key left, the ZXCV row 0.5 key right.
    let step = keySize + gap
    let rows: [(dy: CGFloat, dx: CGFloat, keys: [(String, String)])] = [
        (step, -0.25, [("q", "ㅂ"), ("w", "ㅈ"), ("e", "ㄷ")]),
        (0, 0, [("a", "ㅁ"), ("", ""), ("d", "ㅇ")]),
        (-step, 0.5, [("z", "ㅋ"), ("x", "ㅌ"), ("c", "ㅊ")]),
    ]
    for row in rows {
        for (i, legends) in row.keys.enumerated() where !(row.dy == 0 && i == 1) {
            let r = key.offsetBy(dx: (CGFloat(i - 1) + row.dx) * step, dy: row.dy)
            drawKey(r, radius: radius, ctx: ctx)
            let li = keySize * 0.15
            drawText(legends.0, font: font(["SFPro-Regular"], size: keySize * 0.3, weight: .regular),
                     color: color(legend, 0.35), at: CGPoint(x: r.maxX - li, y: r.maxY - li), anchor: .topRight)
            drawText(legends.1, font: font(["AppleSDGothicNeo-Regular"], size: keySize * 0.32, weight: .regular),
                     color: color(legend, 0.35), at: CGPoint(x: r.minX + li, y: r.minY + keySize * hangulBottomInset), anchor: .bottomLeft)
        }
    }
}
ctx.restoreGState()   // end tile clip

// Main key gets a soft drop shadow so it lifts off the deck.
ctx.saveGState()
let keyShadow = NSShadow()
keyShadow.shadowColor = color(0x000000, 0.35)
keyShadow.shadowOffset = CGSize(width: 0, height: -10)
keyShadow.shadowBlurRadius = 24
keyShadow.set()
color(wellColor).setFill()
NSBezierPath(roundedRect: key, xRadius: radius, yRadius: radius).fill()
ctx.restoreGState()
drawKey(key, radius: radius, ctx: ctx)

// MARK: Legends — diagonal, like a Korean MacBook key.
let inset: CGFloat = keySize * 0.15
drawText(
    "s",
    font: font(["SFPro-Regular", "SF Pro Text"], size: keySize * 0.36, weight: .regular),
    color: color(legend),
    at: CGPoint(x: key.maxX - inset, y: key.maxY - inset),
    anchor: .topRight
)
drawText(
    "ㄴ",
    font: font(["AppleSDGothicNeo-Regular"], size: keySize * 0.38, weight: .regular),
    color: color(legend),
    at: CGPoint(x: key.minX + inset, y: key.minY + keySize * hangulBottomInset),
    anchor: .bottomLeft
)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")

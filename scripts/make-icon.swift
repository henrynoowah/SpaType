// Renders the SpaType app icon. Usage: swift scripts/make-icon.swift <out.png>
//
// A keycap on a deep ink tile. Like a real Korean keyboard, the key carries two legends:
// the English "spa" that was actually typed (small, accent colour) and the Hangul it was
// meant to be — "넴" — in the middle.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

// MARK: Palette
let tileTop = 0x2B3A55, tileMid = 0x1B2638, tileBottom = 0x0E1521   // ink navy
let capFaceTop = 0xFFFFFF, capFaceBottom = 0xF1F3F7                 // key top
let capSkirtTop = 0xE9ECF2, capSkirtBottom = 0xC5CBD6               // key sides
let legendInk = 0x131A26                                            // "넴"
let accent = 0x3D7BFF                                               // "spa"

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

/// Draws `text` so its visible glyphs (not the line box) are centred on `center`.
func drawText(_ text: String, font: NSFont, color: NSColor, center: CGPoint, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
    str.draw(at: CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY))
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
color(tileMid).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [color(tileTop), color(tileMid), color(tileBottom)], atLocations: [0, 0.5, 1],
           colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// Faint top light so the tile isn't flat.
NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
    .draw(fromCenter: CGPoint(x: 512, y: 960), radius: 0, toCenter: CGPoint(x: 512, y: 960), radius: 560, options: [])
ctx.restoreGState()
// Hairline inner edge.
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 183.5, yRadius: 183.5)
color(0xFFFFFF, 0.08).setStroke()
edge.lineWidth = 3
edge.stroke()

// MARK: Keycap
let capOuter = CGRect(x: 232, y: 214, width: 560, height: 580)
let capOuterPath = NSBezierPath(roundedRect: capOuter, xRadius: 118, yRadius: 118)

ctx.saveGState()
let capShadow = NSShadow()
capShadow.shadowColor = color(0x000000, 0.50)
capShadow.shadowOffset = CGSize(width: 0, height: -24)
capShadow.shadowBlurRadius = 44
capShadow.set()
color(capSkirtBottom).setFill()
capOuterPath.fill()
ctx.restoreGState()

ctx.saveGState()
capOuterPath.addClip()
NSGradient(colors: [color(capSkirtTop), color(capSkirtBottom)])!.draw(in: capOuter, angle: -90)
ctx.restoreGState()

let face = CGRect(x: 272, y: 268, width: 480, height: 490)
let facePath = NSBezierPath(roundedRect: face, xRadius: 92, yRadius: 92)
ctx.saveGState()
facePath.addClip()
NSGradient(colors: [color(capFaceTop), color(capFaceBottom)])!.draw(in: face, angle: -90)
ctx.restoreGState()
color(0xFFFFFF).setStroke()
facePath.lineWidth = 3
facePath.stroke()

// MARK: Legends
drawText(
    "spa",
    font: NSFont.monospacedSystemFont(ofSize: 66, weight: .bold),   // SF Mono
    color: color(accent),
    center: CGPoint(x: 370, y: 690),
    kern: 0
)
drawText(
    "넴",
    font: font(["BMHANNAProOTF", "AppleSDGothicNeo-Bold"], size: 300, weight: .bold),   // 배달의민족 한나 Pro
    color: color(legendInk),
    center: CGPoint(x: 516, y: 452),
    kern: 0
)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")

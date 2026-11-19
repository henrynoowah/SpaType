import AppKit

/// The menu bar icon: a small keycap with "s" top-right and "ㄴ" bottom-left, matching the app icon.
/// Drawn in code as a template image, so macOS tints it for light/dark menu bars and highlights,
/// and it stays sharp at any backing scale.
enum MenuBarIcon {
    enum Style { case filled, outline }

    static func make(style: Style = .filled) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(style: style, in: CGRect(origin: .zero, size: size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SpaType"
        return image
    }

    private static func draw(style: Style, in bounds: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let key = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 3.6

        let latin = NSFont.systemFont(ofSize: 7.4, weight: .heavy)
        let hangul = NSFont(name: "AppleSDGothicNeo-ExtraBold", size: 8.6) ?? latin

        switch style {
        case .filled:
            // Solid key with the legends knocked out of it — reads best at 18pt.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: key, xRadius: radius, yRadius: radius).fill()
            ctx.setBlendMode(.destinationOut)
            legends(in: key, latin: latin, hangul: hangul, color: .black)
            ctx.setBlendMode(.normal)
        case .outline:
            let path = NSBezierPath(roundedRect: key.insetBy(dx: 0.7, dy: 0.7), xRadius: radius - 0.7, yRadius: radius - 0.7)
            path.lineWidth = 1.4
            NSColor.black.setStroke()
            path.stroke()
            legends(in: key, latin: latin, hangul: hangul, color: .black)
        }
    }

    private static func legends(in key: CGRect, latin: NSFont, hangul: NSFont, color: NSColor) {
        draw("s", font: latin, color: color, at: CGPoint(x: key.maxX - 3.0, y: key.maxY - 3.0), topRight: true)
        draw("ㄴ", font: hangul, color: color, at: CGPoint(x: key.minX + 3.0, y: key.minY + 3.0), topRight: false)
    }

    /// Places the visible glyph bounds (not the line box) at a corner.
    private static func draw(_ text: String, font: NSFont, color: NSColor, at point: CGPoint, topRight: Bool) {
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        // Without .usesLineFragmentOrigin both the glyph bounds and the draw point are baseline-relative.
        let b = str.boundingRect(with: .zero, options: [.usesDeviceMetrics])
        let baseline = topRight
            ? CGPoint(x: point.x - b.maxX, y: point.y - b.maxY)
            : CGPoint(x: point.x - b.minX, y: point.y - b.minY)
        str.draw(with: CGRect(origin: baseline, size: .zero), options: [])
    }
}

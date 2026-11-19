import AppKit
import SpaTypeCore

/// A small translucent card that floats under the caret without taking focus.
final class SuggestionPanel {
    private let panel: NSPanel
    private let routeLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Tab 또는 ⇧⇧ 바꾸기 · 계속 입력하면 무시")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true

        routeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        routeLabel.textColor = .secondaryLabelColor
        previewLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [routeLabel, previewLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ suggestion: Suggestion, near caret: NSRect?) {
        routeLabel.stringValue = "\(suggestion.from.displayName) → \(suggestion.target.displayName)"
        previewLabel.stringValue = suggestion.preview

        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let width = min(max(size.width, 180), 470)

        let anchor = caret ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        var origin = NSPoint(x: anchor.minX - 8, y: anchor.minY - size.height - 6)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchor.maxY + 6 }   // no room below: show above
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: size.height)), display: true)
        panel.alphaValue = 0.94
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

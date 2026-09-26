import AppKit

/// Target for the word counter's menu item.
@MainActor
final class WordMenuTarget: NSObject {
    static let shared = WordMenuTarget()
    var action: (() -> Void)?
    @objc func toggle() { action?() }
}

// MARK: - Ghost text overlay

/// A click-through, non-activating panel that shows the suggestion: inline in grey right after the
/// cursor when the app reports where it is, otherwise as a small glass bubble under the field or at
/// the bottom of the window.
@MainActor
final class GhostText {
    enum Placement { case inline, below, centred }

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let bubble = NSVisualEffectView()

    func show(_ text: String, hint: String, at anchor: CGRect, placement: Placement, multiline: Bool = false) {
        let p = panel ?? make()
        panel = p
        let inline = placement == .inline
        let size = inline ? min(max(anchor.height * 0.78, 11), 30) : 14
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: inline ? NSColor.secondaryLabelColor.withAlphaComponent(0.75) : NSColor.labelColor,
        ])
        attr.append(NSAttributedString(string: (multiline ? "\n" : "  ") + hint, attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.72, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        label.attributedStringValue = attr
        label.maximumNumberOfLines = multiline ? 14 : 1
        label.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        let maxWidth: CGFloat = multiline ? 480 : 720
        let fit = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: 4000)) ?? label.intrinsicContentSize
        bubble.isHidden = inline
        let padX: CGFloat = inline ? 2 : 10, padY: CGFloat = inline ? 0 : 6
        let size2 = NSSize(width: min(ceil(fit.width), maxWidth) + padX * 2, height: ceil(fit.height) + padY * 2)
        // AX uses a top-left origin on the primary display; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin: NSPoint
        switch placement {
        case .inline:
            origin = NSPoint(x: anchor.maxX + 1, y: primaryHeight - anchor.maxY + (anchor.height - size2.height) / 2)
        case .below:
            origin = NSPoint(x: anchor.minX, y: primaryHeight - anchor.minY - size2.height)
        case .centred:
            origin = NSPoint(x: anchor.midX - size2.width / 2, y: primaryHeight - anchor.minY - size2.height)
        }
        // Keep a bubble on screen (a long draft under a field near the bottom would otherwise run off it).
        if !inline, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: primaryHeight - anchor.midY)) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - size2.width - 8)
            if origin.y < v.minY + 8 { origin.y = primaryHeight - anchor.minY + 26 }   // flip above the anchor
        }
        p.setFrame(NSRect(origin: origin, size: size2), display: true)
        bubble.frame = NSRect(origin: .zero, size: size2)
        label.frame = NSRect(x: padX, y: padY, width: size2.width - padX * 2, height: size2.height - padY * 2)
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.material = .popover
        bubble.blendingMode = .behindWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 9
        bubble.layer?.masksToBounds = true
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
        p.contentView?.addSubview(bubble)
        p.contentView?.addSubview(label)
        return p
    }
}

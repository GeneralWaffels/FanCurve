import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Rectangle-style window snapping (halves, thirds, quarters, maximise, centre, next display) through
/// Accessibility, for when AeroSpace isn't tiling the window.
@MainActor
enum WindowSnap {
    struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        /// The target frame as fractions of the screen's visible area (x, y from top-left, w, h).
        let rect: CGRect?
    }

    static let actions: [Action] = [
        Action(id: "left", title: "Left Half", symbol: "rectangle.lefthalf.filled", rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        Action(id: "right", title: "Right Half", symbol: "rectangle.righthalf.filled", rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        Action(id: "top", title: "Top Half", symbol: "rectangle.tophalf.filled", rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)),
        Action(id: "bottom", title: "Bottom Half", symbol: "rectangle.bottomhalf.filled", rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
        Action(id: "max", title: "Maximise", symbol: "rectangle.fill", rect: CGRect(x: 0, y: 0, width: 1, height: 1)),
        Action(id: "almost", title: "Almost Maximise", symbol: "rectangle.inset.filled", rect: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)),
        Action(id: "centre", title: "Centre", symbol: "rectangle.center.inset.filled", rect: nil),
        Action(id: "third1", title: "First Third", symbol: "rectangle.leadingthird.inset.filled", rect: CGRect(x: 0, y: 0, width: 1 / 3, height: 1)),
        Action(id: "third2", title: "Centre Third", symbol: "rectangle.center.inset.filled", rect: CGRect(x: 1 / 3, y: 0, width: 1 / 3, height: 1)),
        Action(id: "third3", title: "Last Third", symbol: "rectangle.trailingthird.inset.filled", rect: CGRect(x: 2 / 3, y: 0, width: 1 / 3, height: 1)),
        Action(id: "twothirds1", title: "First Two Thirds", symbol: "rectangle.leadinghalf.inset.filled", rect: CGRect(x: 0, y: 0, width: 2 / 3, height: 1)),
        Action(id: "twothirds2", title: "Last Two Thirds", symbol: "rectangle.trailinghalf.inset.filled", rect: CGRect(x: 1 / 3, y: 0, width: 2 / 3, height: 1)),
        Action(id: "q1", title: "Top Left Quarter", symbol: "rectangle.inset.topleft.filled", rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        Action(id: "q2", title: "Top Right Quarter", symbol: "rectangle.inset.topright.filled", rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        Action(id: "q3", title: "Bottom Left Quarter", symbol: "rectangle.inset.bottomleft.filled", rect: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
        Action(id: "q4", title: "Bottom Right Quarter", symbol: "rectangle.inset.bottomright.filled", rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        Action(id: "display", title: "Next Display", symbol: "rectangle.portrait.and.arrow.right", rect: nil),
    ]

    /// Frame for `action` inside `visible` (AX coordinates, top-left origin). `current` is the window's frame.
    static func target(_ action: Action, in visible: CGRect, current: CGRect) -> CGRect {
        guard let r = action.rect else {
            let size = CGSize(width: min(current.width, visible.width), height: min(current.height, visible.height))
            return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        }
        return CGRect(x: visible.minX + r.minX * visible.width, y: visible.minY + r.minY * visible.height,
                      width: r.width * visible.width, height: r.height * visible.height).integral
    }

    /// Applies an action to the focused window of the frontmost app (or `app`).
    static func run(_ id: String, app: NSRunningApplication? = nil) {
        guard let action = actions.first(where: { $0.id == id }) else { return }
        guard AXIsProcessTrusted() else { AccessibilityPermission.shared.request(); return }
        guard let front = app ?? NSWorkspace.shared.frontmostApplication else { return }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &w) == .success, let w else { NSSound.beep(); return }
        let window = w as! AXUIElement
        guard let current = frame(window) else { NSSound.beep(); return }

        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        // AppKit screens use a bottom-left origin; AX uses top-left on the primary display.
        func axRect(_ s: NSScreen) -> CGRect {
            let v = s.visibleFrame
            return CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height)
        }
        let centre = CGPoint(x: current.midX, y: current.midY)
        let index = screens.firstIndex { axRect($0).insetBy(dx: -1, dy: -40).contains(centre) } ?? 0
        if id == "display" {
            guard screens.count > 1 else { return }
            let from = axRect(screens[index]), to = axRect(screens[(index + 1) % screens.count])
            // Keep the same relative position and size on the next screen.
            let rel = CGRect(x: (current.minX - from.minX) / from.width, y: (current.minY - from.minY) / from.height,
                             width: current.width / from.width, height: current.height / from.height)
            set(window, CGRect(x: to.minX + rel.minX * to.width, y: to.minY + rel.minY * to.height,
                               width: min(rel.width, 1) * to.width, height: min(rel.height, 1) * to.height).integral)
            return
        }
        set(window, target(action, in: axRect(screens[index]), current: current))
    }

    private static func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Size, then position, then size again: some apps clamp the size to the screen they're on first.
    private static func set(_ w: AXUIElement, _ r: CGRect) {
        var point = r.origin, size = r.size
        guard let pv = AXValueCreate(.cgPoint, &point), let sv = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
    }
}

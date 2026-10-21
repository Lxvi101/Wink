import AppKit
import QuartzCore

/// A second, agent-owned pointer drawn in a click-through overlay. It never moves the user's cursor.
///
/// Motion model: each move flies along a gently arced cubic Bézier whose duration grows with distance,
/// with a slight tilt into the direction of travel, a squash-and-stretch on short hops, a press squash
/// plus ripple when the action lands, and a fade after a few idle seconds. Moves are interruptible:
/// a new target starts from wherever the cursor currently is on screen.
@MainActor
final class GhostCursor {
    static let shared = GhostCursor()

    enum Effect { case none, click, doubleClick, rightClick, type, scroll, drag(to: CGPoint) }

    private var window: NSWindow?
    private let root = CALayer()
    private let cursor = CALayer()
    private let glow = CAShapeLayer()
    private let arrow = CAShapeLayer()
    private var lastPoint: CGPoint?
    private var idleTimer: Timer?
    private var visible = false
    let enabled: Bool
    let topmost: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        enabled = env["PEEKABOO_CUA_CURSOR"].map { !["0", "false", "off"].contains($0.lowercased()) } ?? true
        topmost = env["PEEKABOO_CUA_CURSOR_LEVEL"]?.lowercased() == "top"
    }

    // MARK: Geometry

    /// Global AppKit frame spanning every screen (bottom-left origin).
    private static func desktopFrame() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// Accessibility/CG coordinates (top-left of the primary display) to overlay-layer coordinates.
    private func layerPoint(fromGlobal p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKit = CGPoint(x: p.x, y: primaryHeight - p.y)
        let desk = Self.desktopFrame()
        return CGPoint(x: appKit.x - desk.minX, y: appKit.y - desk.minY)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let frame = Self.desktopFrame()
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.canHide = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.level = topmost ? .screenSaver : .normal
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = root
        root.frame = view.bounds
        w.contentView = view
        buildCursor()
        window = w
        if ProcessInfo.processInfo.environment["PEEKABOO_CUA_DEBUG"] != nil {
            FileHandle.standardError.write("peekaboo-cua: cursor overlay window \(w.windowNumber)\n".data(using: .utf8)!)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.setFrame(Self.desktopFrame(), display: false)
                self.root.frame = CGRect(origin: .zero, size: window.frame.size)
            }
        }
        return w
    }

    private func buildCursor() {
        // Original pointer shape: a rounded dart with the hotspot at (0, 0) — layer space is y-up,
        // so the body extends downward (negative y) and to the right.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: -17.5))
        path.addLine(to: CGPoint(x: 4.4, y: -13.4))
        path.addLine(to: CGPoint(x: 7.5, y: -20.4))
        path.addLine(to: CGPoint(x: 10.6, y: -19.1))
        path.addLine(to: CGPoint(x: 7.6, y: -12.2))
        path.addLine(to: CGPoint(x: 13.4, y: -12.2))
        path.closeSubpath()

        cursor.bounds = CGRect(x: -6, y: -26, width: 32, height: 32)
        cursor.anchorPoint = CGPoint(x: 6.0 / 32.0, y: 26.0 / 32.0) // hotspot
        cursor.opacity = 0

        let accent = NSColor(srgbRed: 0.24, green: 0.47, blue: 1.0, alpha: 1).cgColor
        glow.path = path
        glow.fillColor = accent
        glow.opacity = 0.55
        glow.shadowColor = accent
        glow.shadowOpacity = 1
        glow.shadowRadius = 9
        glow.shadowOffset = .zero
        glow.position = .zero

        arrow.path = path
        arrow.fillColor = accent
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.8
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.28
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: -1)
        arrow.position = .zero

        cursor.addSublayer(glow)
        cursor.addSublayer(arrow)
        root.addSublayer(cursor)
    }

    // MARK: Public API

    /// Animate to `point` (global top-left coordinates), optionally keeping the overlay just above `windowID`.
    /// Returns immediately; the effect plays when the cursor arrives.
    func move(to point: CGPoint, aboveWindow windowID: CGWindowID?, effect: Effect) {
        guard enabled else { return }
        let w = ensureWindow()
        if !topmost, let windowID {
            w.order(.above, relativeTo: Int(windowID))
        } else {
            w.orderFrontRegardless()
        }

        let target = layerPoint(fromGlobal: point)
        let current = (cursor.presentation()?.position).flatMap { visible ? $0 : nil }
            ?? lastPoint.map(layerPoint(fromGlobal:))
            ?? NSEvent.mouseLocation.applying(.init(translationX: -Self.desktopFrame().minX, y: -Self.desktopFrame().minY))
        lastPoint = point

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursor.removeAnimation(forKey: "move")
        cursor.removeAnimation(forKey: "tilt")
        cursor.position = target
        CATransaction.commit()

        if !visible {
            visible = true
            fade(to: 1, duration: 0.12)
        }

        let dx = target.x - current.x, dy = target.y - current.y
        let distance = hypot(dx, dy)
        let duration = distance < 2 ? 0.0 : min(0.52, max(0.16, 0.12 + Double(distance) / 2600))

        if duration > 0 {
            // Arc sideways by ~12% of the distance, bending away from the nearest screen edge.
            let normal = CGPoint(x: -dy / distance, y: dx / distance)
            let bend = min(90, distance * 0.12) * (dx >= 0 ? 1 : -1)
            let c1 = CGPoint(x: current.x + dx * 0.3 + normal.x * bend, y: current.y + dy * 0.3 + normal.y * bend)
            let c2 = CGPoint(x: current.x + dx * 0.75 + normal.x * bend * 0.45, y: current.y + dy * 0.75 + normal.y * bend * 0.45)
            let path = CGMutablePath()
            path.move(to: current)
            path.addCurve(to: target, control1: c1, control2: c2)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.duration = duration
            move.calculationMode = .paced
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.2, 1.0)
            cursor.add(move, forKey: "move")

            // Lean into the motion, then settle with a small overshoot.
            let lean = max(-0.28, min(0.28, -dx / 900))
            let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            tilt.values = [0, lean, lean * 0.6, -lean * 0.18, 0]
            tilt.keyTimes = [0, 0.25, 0.7, 0.9, 1]
            tilt.duration = duration + 0.12
            cursor.add(tilt, forKey: "tilt")

            if distance < 80 {
                let squash = CAKeyframeAnimation(keyPath: "transform.scale.x")
                squash.values = [1, 1.12, 0.94, 1]
                squash.keyTimes = [0, 0.35, 0.75, 1]
                squash.duration = duration + 0.08
                cursor.add(squash, forKey: "squash")
            }
        }

        let arrival = duration
        DispatchQueue.main.asyncAfter(deadline: .now() + arrival) { [weak self] in
            MainActor.assumeIsolated { self?.land(effect: effect, at: target) }
        }
        scheduleIdleFade(after: arrival + 2.6)
    }

    private func land(effect: Effect, at point: CGPoint) {
        switch effect {
        case .none:
            break
        case .click, .rightClick:
            press()
            ripple(at: point, color: effect.isRight ? NSColor.systemPurple : nil)
        case .doubleClick:
            press()
            ripple(at: point, color: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
                MainActor.assumeIsolated { self?.ripple(at: point, color: nil) }
            }
        case .type:
            pulse()
        case .scroll:
            pulse()
        case let .drag(to):
            press()
            move(to: to, aboveWindow: nil, effect: .click)
        }
    }

    private func press() {
        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1, 0.8, 1.06, 1]
        squash.keyTimes = [0, 0.3, 0.7, 1]
        squash.duration = 0.26
        cursor.add(squash, forKey: "press")
    }

    private func pulse() {
        let glowPulse = CAKeyframeAnimation(keyPath: "shadowRadius")
        glowPulse.values = [9, 16, 9]
        glowPulse.duration = 0.4
        glow.add(glowPulse, forKey: "pulse")
    }

    private func ripple(at point: CGPoint, color: NSColor?) {
        let ring = CAShapeLayer()
        let r: CGFloat = 16
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.position = point
        ring.fillColor = (color ?? NSColor(srgbRed: 0.24, green: 0.47, blue: 1, alpha: 1)).withAlphaComponent(0.18).cgColor
        ring.strokeColor = (color ?? NSColor(srgbRed: 0.24, green: 0.47, blue: 1, alpha: 1)).cgColor
        ring.lineWidth = 2
        root.insertSublayer(ring, below: cursor)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.25
        scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { ring.removeFromSuperlayer() }
    }

    private func fade(to opacity: Float, duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = cursor.presentation()?.opacity ?? cursor.opacity
        anim.toValue = opacity
        anim.duration = duration
        cursor.opacity = opacity
        cursor.add(anim, forKey: "fade")
    }

    private func scheduleIdleFade(after seconds: TimeInterval) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.visible = false
                self.fade(to: 0, duration: 0.35)
            }
        }
    }
}

private extension GhostCursor.Effect {
    var isRight: Bool { if case .rightClick = self { true } else { false } }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

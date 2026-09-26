import AppKit
import QuartzCore

/// A transparent layer over the recorded screen, and part of the recording:
/// it shows every click as a burst — a ring opening out and small dots flying
/// away from the pointer — and, while drawing is switched on, takes the mouse
/// so the presenter can sketch over whatever is on screen. Each stroke fades
/// away on its own a moment after it is finished, as in Loom, so the screen
/// never fills up with old marks.
///
/// Clicks are observed with a global mouse monitor, which needs no permission:
/// only a global *keyboard* monitor does. Nothing about the click is recorded
/// except the burst drawn on screen.
@MainActor
final class RecordingCanvas {
    private let window: RecordableWindow
    private let view: CanvasView
    private var monitor: Any?
    private let showsClicks: Bool

    private(set) var isDrawing = false

    init(screen: NSScreen, showsClicks: Bool) {
        self.showsClicks = showsClicks
        window = RecordableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        view = CanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = RecordableWindow.canvas
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Has to be capturable, whatever "hide CopyWell from recordings" says.
        window.sharingType = .readOnly
        window.setFrame(screen.frame, display: false)
        view.wantsLayer = true
        window.contentView = view
    }

    /// The window's id, so the recording can include it while leaving the
    /// rest of CopyWell out.
    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    /// Puts the (empty, transparent) window on screen. It has to be there
    /// before ScreenCaptureKit is asked what windows exist.
    func show() {
        window.orderFrontRegardless()
    }

    func start() {
        show()
        guard showsClicks else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let location = NSEvent.mouseLocation
            let secondary = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.burst(at: location, secondary: secondary) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setDrawing(false)
        window.orderOut(nil)
    }

    /// While drawing, the canvas takes the mouse; the rest of the time every
    /// click passes straight through to the apps being recorded.
    func setDrawing(_ drawing: Bool) {
        isDrawing = drawing
        window.ignoresMouseEvents = !drawing
        view.isDrawingEnabled = drawing
        window.invalidateCursorRects(for: view)
    }

    // MARK: - The burst

    func burst(at screenPoint: CGPoint, secondary: Bool) {
        guard window.frame.contains(screenPoint), let host = view.layer else { return }
        let point = CGPoint(x: screenPoint.x - window.frame.minX, y: screenPoint.y - window.frame.minY)
        let color = secondary ? NSColor.systemOrange : NSColor.controlAccentColor

        let group = CALayer()
        group.frame = host.bounds
        host.addSublayer(group)

        CATransaction.begin()
        CATransaction.setCompletionBlock { group.removeFromSuperlayer() }

        // A soft filled disc under the pointer, so the spot reads even in a
        // small video.
        let disc = circle(radius: 16, at: point)
        disc.fillColor = color.withAlphaComponent(0.28).cgColor
        group.addSublayer(disc)
        animate(disc, duration: 0.45, scale: (0.4, 1.0), opacity: (1, 0))

        // The ring opening out, with a glow in the same colour.
        let ring = circle(radius: 24, at: point)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        ring.shadowColor = color.cgColor
        ring.shadowOpacity = 0.8
        ring.shadowRadius = 5
        ring.shadowOffset = .zero
        group.addSublayer(ring)
        animate(ring, duration: 0.55, scale: (0.25, 1.35), opacity: (0.95, 0))

        // A fine white ring just inside it: the accent colour alone faded
        // into dark backgrounds in test recordings.
        let halo = circle(radius: 21.5, at: point)
        halo.fillColor = nil
        halo.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        halo.lineWidth = 1.2
        group.addSublayer(halo)
        animate(halo, duration: 0.55, scale: (0.25, 1.35), opacity: (0.9, 0))

        // The dots flying away from the centre.
        let count = 10
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi + (secondary ? .pi / CGFloat(count) : 0)
            let dot = circle(radius: index.isMultiple(of: 2) ? 3.5 : 2.5, at: point)
            dot.fillColor = color.cgColor
            dot.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            dot.lineWidth = 0.8
            dot.shadowColor = color.cgColor
            dot.shadowOpacity = 0.9
            dot.shadowRadius = 3
            dot.shadowOffset = .zero
            group.addSublayer(dot)

            let distance: CGFloat = index.isMultiple(of: 2) ? 42 : 32
            let target = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: point)
            move.toValue = NSValue(point: target)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.3
            let animation = CAAnimationGroup()
            animation.animations = [move, fade, shrink]
            animation.duration = 0.6
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.8, 0.3, 1)
            dot.position = target
            dot.opacity = 0
            dot.add(animation, forKey: "fly")
        }

        CATransaction.commit()
    }

    private func circle(radius: CGFloat, at point: CGPoint) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.position = point
        layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        return layer
    }

    private func animate(_ layer: CALayer, duration: CFTimeInterval, scale: (CGFloat, CGFloat), opacity: (Float, Float)) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = scale.0
        grow.toValue = scale.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        fade.toValue = opacity.1
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = opacity.1
        layer.transform = CATransform3DMakeScale(scale.1, scale.1, 1)
        layer.add(group, forKey: "burst")
    }
}

/// Takes the mouse while drawing is on and turns each drag into a stroke that
/// fades out a couple of seconds after the button comes up.
private final class CanvasView: NSView {
    var isDrawingEnabled = false
    private var stroke: CAShapeLayer?
    private var path = CGMutablePath()
    private var lastPoint: CGPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isDrawingEnabled { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isDrawingEnabled, let host = layer else { return }
        let point = convert(event.locationInWindow, from: nil)
        path = CGMutablePath()
        path.move(to: point)
        lastPoint = point
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.fillColor = nil
        layer.strokeColor = NSColor.systemRed.cgColor
        layer.lineWidth = 5
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.path = path
        host.addSublayer(layer)
        stroke = layer
    }

    override func mouseDragged(with event: NSEvent) {
        guard let stroke else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mid = CGPoint(x: (lastPoint.x + point.x) / 2, y: (lastPoint.y + point.y) / 2)
        path.addQuadCurve(to: mid, control: lastPoint)
        lastPoint = point
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.path = path
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke else { return }
        self.stroke = nil
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 2.2
        fade.duration = 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { stroke.removeFromSuperlayer() }
        stroke.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

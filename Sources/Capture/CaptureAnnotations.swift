import AppKit
import CoreImage
import Foundation

/// The drawing tools on the screenshot overlay.
///
/// `nil` in the overlay means no tool: the selection itself can be moved and
/// resized. Picking a tool switches the mouse over to drawing inside it.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case pen
    case line
    case arrow
    case rectangle
    case ellipse
    case marker
    case text
    case pixelate

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "mosaic"
        }
    }

    var title: String {
        switch self {
        case .pen: return L("Pen")
        case .line: return L("Line")
        case .arrow: return L("Arrow")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .marker: return L("Marker")
        case .text: return L("Text")
        case .pixelate: return L("Blur")
        }
    }

    /// The physical key, whatever the keyboard layout: on a Russian layout
    /// the P key types "з", and matching on the character found nothing.
    var keyCode: UInt16 {
        switch self {
        case .pen: return 35       // P
        case .line: return 37      // L
        case .arrow: return 0      // A
        case .rectangle: return 15 // R
        case .ellipse: return 31   // O
        case .marker: return 46    // M
        case .text: return 17      // T
        case .pixelate: return 11  // B
        }
    }

    /// Single letters, pressed without modifiers while the overlay is up.
    var key: Character {
        switch self {
        case .pen: return "p"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .marker: return "m"
        case .text: return "t"
        case .pixelate: return "b"
        }
    }
}

/// The palette offered for annotations. Few on purpose: a screenshot is marked
/// up in seconds, and a colour well would take longer than the drawing.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, black, white

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 0.96, green: 0.23, blue: 0.21, alpha: 1)
        case .orange: return NSColor(srgbRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
        case .green: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        case .black: return NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        case .white: return .white
        }
    }

    var title: String {
        switch self {
        case .red: return L("Red")
        case .orange: return L("Orange")
        case .yellow: return L("Yellow")
        case .green: return L("Green")
        case .blue: return L("Blue")
        case .purple: return L("Purple")
        case .black: return L("Black")
        case .white: return L("White")
        }
    }
}

enum AnnotationWidth: Int, CaseIterable, Identifiable {
    case thin = 2
    case medium = 4
    case thick = 8

    var id: Int { rawValue }
    var points: CGFloat { CGFloat(rawValue) }

    /// Text scales with the chosen width, so one control covers both.
    var fontSize: CGFloat {
        switch self {
        case .thin: return 16
        case .medium: return 22
        case .thick: return 32
        }
    }

    var title: String {
        switch self {
        case .thin: return L("Thin")
        case .medium: return L("Medium")
        case .thick: return L("Thick")
        }
    }
}

/// One mark drawn on a screenshot, in the overlay's own coordinates (points,
/// origin at the bottom left of the screen it was drawn on).
struct Annotation {
    enum Shape {
        case pen([CGPoint])
        case marker([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rectangle(CGPoint, CGPoint)
        case ellipse(CGPoint, CGPoint)
        case text(String, origin: CGPoint, fontSize: CGFloat)
        case pixelate(CGPoint, CGPoint)
    }

    var shape: Shape
    var color: NSColor
    var width: CGFloat

    /// Continues a drag. Freehand tools collect points; everything else moves
    /// its second corner.
    mutating func extend(to point: CGPoint) {
        switch shape {
        case .pen(let points): shape = .pen(points + [point])
        case .marker(let points): shape = .marker(points + [point])
        case .line(let a, _): shape = .line(a, point)
        case .arrow(let a, _): shape = .arrow(a, point)
        case .rectangle(let a, _): shape = .rectangle(a, point)
        case .ellipse(let a, _): shape = .ellipse(a, point)
        case .pixelate(let a, _): shape = .pixelate(a, point)
        case .text: break
        }
    }

    /// A click without a drag leaves a shape with no size; it is dropped rather
    /// than kept as an invisible entry that Undo would have to step through.
    var isMeaningful: Bool {
        switch shape {
        case .pen(let points), .marker(let points): return points.count > 1
        case .line(let a, let b), .arrow(let a, let b):
            return hypot(b.x - a.x, b.y - a.y) > 3
        case .rectangle(let a, let b), .ellipse(let a, let b), .pixelate(let a, let b):
            return abs(b.x - a.x) > 3 && abs(b.y - a.y) > 3
        case .text(let string, _, _):
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isBlur: Bool {
        if case .pixelate = shape { return true }
        return false
    }

    static func make(tool: AnnotationTool, at point: CGPoint, color: NSColor, width: AnnotationWidth) -> Annotation? {
        let shape: Shape
        switch tool {
        case .pen: shape = .pen([point])
        case .marker: shape = .marker([point])
        case .line: shape = .line(point, point)
        case .arrow: shape = .arrow(point, point)
        case .rectangle: shape = .rectangle(point, point)
        case .ellipse: shape = .ellipse(point, point)
        case .pixelate: shape = .pixelate(point, point)
        case .text: return nil
        }
        return Annotation(shape: shape, color: color, width: width.points)
    }

    // MARK: - Drawing

    /// Draws the mark. The same code draws the overlay on screen and the final
    /// picture, so what is copied is exactly what was seen.
    ///
    /// - Parameter pixelated: the whole screen, already pixelated, laid out in
    ///   the same coordinates as `ctx`. Blur regions are cut out of it.
    func draw(in ctx: CGContext, pixelated: CGImage?, imageBounds: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)

        switch shape {
        case .pen(let points):
            applyShadow(in: ctx)
            stroke(points, in: ctx)

        case .marker(let points):
            ctx.setStrokeColor(color.withAlphaComponent(0.38).cgColor)
            ctx.setLineWidth(max(width * 4, 14))
            ctx.setLineCap(.square)
            // Multiply keeps the text underneath readable, the way a real
            // highlighter does, instead of painting over it.
            ctx.setBlendMode(.multiply)
            stroke(points, in: ctx)

        case .line(let a, let b):
            applyShadow(in: ctx)
            stroke([a, b], in: ctx)

        case .arrow(let a, let b):
            // One shadow for the whole shape; filling and outlining it
            // separately would cast two.
            applyShadow(in: ctx, deep: true)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawArrow(from: a, to: b, in: ctx)
            ctx.endTransparencyLayer()

        case .rectangle(let a, let b):
            applyShadow(in: ctx)
            let box = Self.rect(a, b).insetBy(dx: width / 2, dy: width / 2)
            // Slightly rounded corners, in proportion to the line.
            let radius = min(width * 1.2, box.width / 2, box.height / 2)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()

        case .ellipse(let a, let b):
            applyShadow(in: ctx)
            ctx.strokeEllipse(in: Self.rect(a, b).insetBy(dx: width / 2, dy: width / 2))

        case .text(let string, let origin, let fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: string, attributes: attributes).draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()

        case .pixelate(let a, let b):
            let area = Self.rect(a, b)
            if let pixelated {
                ctx.clip(to: area)
                ctx.draw(pixelated, in: imageBounds)
            } else {
                // Recording mode has no frozen picture to pixelate; a solid
                // block still hides what is underneath.
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(area)
            }
        }
    }

    private func stroke(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        if points.count == 1 {
            ctx.addLine(to: first)
        } else {
            // Midpoint smoothing: freehand input arrives as a jagged polyline
            // at the mouse's sampling rate, and this turns it into a curve.
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                ctx.addQuadCurve(to: mid, control: previous)
            }
            ctx.addLine(to: points[points.count - 1])
        }
        ctx.strokePath()
    }

    /// A skeuomorphic arrow, in the tradition of Skitch: one solid shape with
    /// a white rim like a sticker, shaded as a rounded tube lit from the top of
    /// the screen, a gloss along its upper edge and a shadow that lifts it off
    /// the picture. The shaft tapers from a fine round tail to a full neck and
    /// the barbs sweep back past it, so it reads as a single object.
    private func drawArrow(from a: CGPoint, to b: CGPoint, in ctx: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length   // along the arrow
        var nx = -uy, ny = ux                     // across it
        // Light comes from the top of the screen whichever way the arrow
        // points, so "across" is turned to face up.
        if ny < 0 || (ny == 0 && nx < 0) { nx = -nx; ny = -ny }

        let headLength = min(max(width * 5, 20), length * 0.75)
        let headHalfWidth = max(width * 2.6, 9)
        let neckHalfWidth = max(width * 1.0, 2.2)
        let tailHalfWidth = max(width * 0.35, 1)
        let neck = headLength * 0.68

        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: a.x + ux * along + nx * across, y: a.y + uy * along + ny * across)
        }

        // Built with the same winding whichever way "across" faces.
        let path = CGMutablePath()
        path.move(to: point(0, tailHalfWidth))
        path.addLine(to: point(length - neck, neckHalfWidth))
        path.addLine(to: point(length - headLength, headHalfWidth))
        path.addLine(to: point(length, 0))
        path.addLine(to: point(length - headLength, -headHalfWidth))
        path.addLine(to: point(length - neck, -neckHalfWidth))
        path.addLine(to: point(0, -tailHalfWidth))
        // Round the tail as part of the one outline — a separate disc left
        // its own edge showing across the shaft. The arc runs round the back,
        // which is clockwise or not depending on which way "across" was turned.
        path.addArc(center: a, radius: tailHalfWidth,
                    startAngle: atan2(-ny, -nx), endAngle: atan2(ny, nx),
                    clockwise: ux * ny - uy * nx > 0)
        path.closeSubpath()
        let shape = path

        // 1. The white rim: a wide stroke, most of which the body covers.
        let rim = max(1.6, width * 0.42)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(rim * 2)
        ctx.addPath(shape)
        ctx.strokePath()

        // 2. The body, shaded across its width: lighter on the lit side,
        //    deeper on the other. The gradient spans the shaft, and the
        //    head takes the colours at either end of it.
        let base = color.usingColorSpace(.sRGB) ?? color
        let light = base.blended(withFraction: 0.38, of: .white) ?? base
        let deep = base.blended(withFraction: 0.32, of: .black) ?? base
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let body = CGGradient(colorsSpace: space,
                                 colors: [light.cgColor, base.cgColor, deep.cgColor] as CFArray,
                                 locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(body, start: point(length / 2, neckHalfWidth * 1.4),
                                   end: point(length / 2, -neckHalfWidth * 1.4),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // 3. The gloss: a sheen over the lit half, fading out by the middle.
        if let gloss = CGGradient(colorsSpace: space,
                                  colors: [NSColor.white.withAlphaComponent(0.45).cgColor,
                                           NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
            ctx.drawLinearGradient(gloss, start: point(length / 2, neckHalfWidth * 1.1),
                                   end: point(length / 2, 0),
                                   options: [.drawsBeforeStartLocation])
        }
        ctx.restoreGState()

        // 4. A fine darker edge, so the shape stays crisp against its rim.
        ctx.setStrokeColor(deep.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(max(0.6, width * 0.12))
        ctx.addPath(shape)
        ctx.strokePath()
    }

    /// A soft shadow under a mark, so a red arrow stays readable on red and
    /// a white one on white. Shadow offsets and blur are in device pixels, not
    /// in the context's units, so they are scaled here to look the same on
    /// screen and in the full-resolution copy.
    private func applyShadow(in ctx: CGContext, deep: Bool = false) {
        let transform = ctx.ctm
        let scale = max(hypot(transform.a, transform.b), 1)
        ctx.setShadow(
            offset: CGSize(width: 0, height: (deep ? -2.5 : -1.2) * scale),
            blur: (deep ? 6 : 3.5) * scale,
            color: NSColor.black.withAlphaComponent(deep ? 0.5 : 0.38).cgColor
        )
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

enum CaptureImaging {
    /// The whole screenshot pixelated once, so every blur region is a clip of
    /// the same picture instead of a fresh filter pass on each mouse move.
    static func pixelated(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(12, 10 * scale), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent)
    }

    /// PNG with the screen's resolution recorded in it. Without the point size
    /// a Retina screenshot pastes into documents at twice its real size, the
    /// way a 72-dpi picture of 2× pixels would.
    static func png(from image: CGImage, pointSize: CGSize) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        return rep.representation(using: .png, properties: [:])
    }
}

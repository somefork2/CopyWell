import AppKit
import Observation
import SwiftUI

enum CaptureMode {
    case screenshot
    case recording
}

enum CaptureAction {
    case copy
    case save
    case copyText
    case record
    case undo
    case cancel
    /// Recording: the whole screen, one window, or one app.
    case recordScreen
    case recordWindow
    case recordApp
}

/// What the toolbars show and change. Shared by the overlays on every screen,
/// so a tool picked on one display is the tool on all of them.
@MainActor
@Observable
final class CaptureToolState {
    var tool: AnnotationTool? { didSet { onChange?() } }
    var color: AnnotationColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "capture_color") }
    }
    var width: AnnotationWidth {
        didSet { UserDefaults.standard.set(width.rawValue, forKey: "capture_width") }
    }
    var canUndo = false

    @ObservationIgnored var onChange: (() -> Void)?

    /// The control under the mouse. The overlay draws its tooltip itself:
    /// the system's tooltips open in a window below the overlay's level, so
    /// every `.help` on these bars was there and could never be seen.
    @ObservationIgnored var hoveredTip: CaptureTipTarget? {
        didSet { if hoveredTip != oldValue { onTipChange?() } }
    }
    /// Where each control sits inside its bar, as SwiftUI laid it out.
    @ObservationIgnored var tipFrames: [String: CGRect] = [:]
    @ObservationIgnored var onTipChange: (() -> Void)?

    init() {
        color = UserDefaults.standard.string(forKey: "capture_color").flatMap(AnnotationColor.init(rawValue:)) ?? .red
        width = AnnotationWidth(rawValue: UserDefaults.standard.integer(forKey: "capture_width")) ?? .medium
    }
}

/// A borderless window covering one screen. Borderless windows refuse the
/// keyboard unless told otherwise, and the overlay needs it for ⎋, ⏎ and ⌘C.
final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
protocol CaptureOverlayDelegate: AnyObject {
    func overlayDidBeginSelection(_ overlay: CaptureOverlayView)
    func overlay(_ overlay: CaptureOverlayView, perform action: CaptureAction)
    func overlay(_ overlay: CaptureOverlayView, keyDown event: NSEvent) -> Bool
}

/// One screen's worth of the capture overlay: the frozen picture (for
/// screenshots) or the live screen (for recordings), dimmed outside the
/// selection, with the marks drawn on top and the two toolbars beside it.
@MainActor
final class CaptureOverlayView: NSView, NSTextFieldDelegate {
    let mode: CaptureMode
    let snapshot: CGImage?
    let state: CaptureToolState
    weak var delegate: CaptureOverlayDelegate?

    private(set) var selection: CGRect? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private var annotations: [Annotation] = [] {
        didSet { state.canUndo = !annotations.isEmpty }
    }
    private var inProgress: Annotation?
    private var drag: Drag = .none
    /// Built the first time a blur is drawn, not when the overlay opens: it is
    /// a filter pass over the whole screen, and the overlay has to appear the
    /// instant the shortcut is pressed.
    private var pixelatedCache: CGImage??
    private var pixelated: CGImage? {
        if let pixelatedCache { return pixelatedCache }
        let made = snapshot.flatMap { CaptureImaging.pixelated($0, scale: pixelScale) }
        pixelatedCache = .some(made)
        return made
    }

    private var textField: NSTextField?
    private var toolsBar: NSView?
    private var actionBar: NSView?
    private var tipLabel: CaptureTipLabel?
    private var tipWork: DispatchWorkItem?

    private enum Drag {
        case none
        case selecting(start: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(Handle, start: CGPoint, original: CGRect)
        case drawing
    }

    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    }

    init(frame: CGRect, mode: CaptureMode, snapshot: CGImage?, state: CaptureToolState) {
        self.mode = mode
        self.snapshot = snapshot
        self.state = state
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hasSelection: Bool { selection != nil }

    /// Pixels per point of the frozen picture, which is what sizes are shown in.
    private var pixelScale: CGFloat {
        if let snapshot { return CGFloat(snapshot.width) / max(bounds.width, 1) }
        return window?.backingScaleFactor ?? 2
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let snapshot {
            ctx.interpolationQuality = .high
            ctx.draw(snapshot, in: bounds)
        }

        // Dim everything outside the selection. Even-odd filling leaves the
        // selection untouched, which in recording mode means truly transparent:
        // the live screen shows through.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let selection {
            ctx.addRect(bounds)
            ctx.addRect(selection)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }

        guard let selection else {
            drawHint(in: ctx)
            return
        }

        ctx.saveGState()
        ctx.clip(to: selection)
        for annotation in annotations {
            annotation.draw(in: ctx, pixelated: annotation.isBlur ? pixelated : nil, imageBounds: bounds)
        }
        if let inProgress {
            inProgress.draw(in: ctx, pixelated: inProgress.isBlur ? pixelated : nil, imageBounds: bounds)
        }
        ctx.restoreGState()

        drawFrame(around: selection, in: ctx)
        drawSizeLabel(for: selection)
    }

    private func drawFrame(around selection: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        let frame = selection.insetBy(dx: -0.5, dy: -0.5)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.stroke(frame)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(frame)
        ctx.setLineDash(phase: 0, lengths: [])

        for handle in Handle.allCases {
            let rect = handleRect(handle, in: selection, size: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
    }

    private func drawSizeLabel(for selection: CGRect) {
        let scale = pixelScale
        let text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + size.height + 6 > bounds.maxY { origin.y = selection.maxY - size.height - 10 }
        let background = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 2))
    }

    private func drawHint(in ctx: CGContext) {
        let text = mode == .screenshot
            ? L("Drag to select an area · Click to capture the whole screen · Esc to cancel")
            : L("Drag to select the area to record · Click to record the whole screen · Esc to cancel")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(
            x: bounds.midX - size.width / 2 - 16,
            y: bounds.midY - size.height / 2 - 10,
            width: size.width + 32,
            height: size.height + 20
        )
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        string.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10))
    }

    // MARK: - Handles

    private func handlePoint(_ handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleRect(_ handle: Handle, in rect: CGRect, size: CGFloat) -> CGRect {
        let point = handlePoint(handle, in: rect)
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handleRect($0, in: rect, size: 14).contains(point) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let selection else { return }
        switch state.tool {
        case nil: addCursorRect(selection, cursor: .openHand)
        case .text?: addCursorRect(selection, cursor: .iBeam)
        default: break
        }
        for handle in Handle.allCases {
            let cursor: NSCursor
            switch handle {
            case .left, .right: cursor = .resizeLeftRight
            case .top, .bottom: cursor = .resizeUpDown
            default: cursor = .crosshair
            }
            addCursorRect(handleRect(handle, in: selection, size: 14), cursor: cursor)
        }
        for bar in [toolsBar, actionBar].compactMap({ $0 }) where !bar.isHidden {
            addCursorRect(bar.frame, cursor: .arrow)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commitText()
        hideTip()

        if let selection {
            if let handle = handle(at: point, in: selection) {
                drag = .resizing(handle, start: point, original: selection)
                return
            }
            if mode == .screenshot, let tool = state.tool {
                // Marks are made inside the selection only; a stray click
                // outside it with a tool in hand does nothing rather than
                // throwing the selection and its drawing away.
                guard selection.contains(point) else { return }
                if tool == .text {
                    beginText(at: point)
                } else {
                    inProgress = Annotation.make(tool: tool, at: point, color: state.color.nsColor, width: state.width)
                    drag = .drawing
                    needsDisplay = true
                }
                return
            }
            if selection.contains(point) {
                drag = .moving(start: point, original: selection)
                NSCursor.closedHand.set()
                return
            }
            // Starting over would discard the drawing; that needs Undo or ⎋.
            guard annotations.isEmpty else { return }
        }

        startSelection(at: point)
    }

    private func startSelection(at point: CGPoint) {
        drag = .selecting(start: point)
        selection = nil
        setBarsHidden(true)
        delegate?.overlayDidBeginSelection(self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .selecting(let start):
            selection = Annotation.rect(start, clamp(point)).integral
        case .moving(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.origin.x, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.origin.y, bounds.minY), bounds.maxY - moved.height)
            selection = moved.integral
            layoutBars()
        case .resizing(let handle, let start, let original):
            selection = resized(original, handle: handle, by: CGPoint(x: point.x - start.x, y: point.y - start.y))
            layoutBars()
        case .drawing:
            guard let selection else { return }
            let clamped = CGPoint(
                x: min(max(point.x, selection.minX), selection.maxX),
                y: min(max(point.y, selection.minY), selection.maxY)
            )
            inProgress?.extend(to: clamped)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .selecting:
            // A click without a drag takes the whole screen.
            if let selection, selection.width >= 4, selection.height >= 4 {
                self.selection = selection
            } else {
                selection = bounds
            }
            setBarsHidden(false)
            layoutBars()
        case .drawing:
            if let inProgress, inProgress.isMeaningful { annotations.append(inProgress) }
            inProgress = nil
        case .moving, .resizing:
            if let selection, selection.width < 4 || selection.height < 4 {
                self.selection = nil
                setBarsHidden(true)
                showDockedBarIfRecording()
            }
        case .none:
            break
        }
        drag = .none
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.overlay(self, perform: .cancel)
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.overlay(self, keyDown: event) != true {
            super.keyDown(with: event)
        }
    }

    /// ⌘ shortcuts are offered here before the menu bar sees them.
    ///
    /// ⌘Z did nothing: the app's Edit menu owns ⌘Z, ⌘C and ⌘A, and with
    /// nothing to undo in CopyWell itself its Undo item is disabled — and a
    /// disabled menu item still swallows its shortcut, with a beep, so the
    /// key never reached `keyDown`. While text is being typed the field keeps
    /// them, so ⌘Z and ⌘A work inside it as they do anywhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              !isEditingText else { return super.performKeyEquivalent(with: event) }
        if delegate?.overlay(self, keyDown: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// For the development diagnostics.
    var annotationCount: Int { annotations.count }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func resized(_ rect: CGRect, handle: Handle, by delta: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: minX += delta.x
        case .right, .topRight, .bottomRight: maxX += delta.x
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY += delta.y
        case .top, .topLeft, .topRight: maxY += delta.y
        default: break
        }
        let result = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        return result.intersection(bounds).integral
    }

    // MARK: - Selection and editing, driven by the session

    func clearSelection() {
        commitText()
        selection = nil
        annotations.removeAll()
        inProgress = nil
        setBarsHidden(true)
        needsDisplay = true
    }

    /// The area to record: the selection, or the whole screen when nothing
    /// was dragged out — pressing Record straight away records everything.
    var recordingArea: CGRect { selection ?? bounds }

    func selectWholeScreen() {
        guard annotations.isEmpty else { return }
        selection = bounds
        setBarsHidden(false)
        layoutBars()
        needsDisplay = true
    }

    func undo() {
        if textField != nil {
            discardText()
            return
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    func toolDidChange() {
        commitText()
        window?.invalidateCursorRects(for: self)
    }

    /// True while a text mark is being typed; the session leaves keys alone then.
    var isEditingText: Bool { textField != nil }

    // MARK: - Text

    private func beginText(at point: CGPoint) {
        let font = NSFont.systemFont(ofSize: state.width.fontSize, weight: .semibold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let field = NSTextField(frame: CGRect(x: point.x - 2, y: point.y - lineHeight / 2, width: 60, height: lineHeight + 2))
        field.font = font
        field.textColor = state.color.nsColor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = L("Text")
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField, let selection else { return }
        let width = (field.attributedStringValue.size().width) + 16
        field.frame.size.width = min(max(width, 60), max(selection.maxX - field.frame.minX, 60))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitText()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            discardText()
            return true
        default:
            return false
        }
    }

    private func commitText() {
        guard let field = textField else { return }
        let string = field.stringValue
        let font = field.font ?? NSFont.systemFont(ofSize: state.width.fontSize)
        // The field draws its text two points in from its left edge and flush
        // with its bottom; the mark goes exactly where the typing was.
        let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.minY + 1)
        let annotation = Annotation(
            shape: .text(string, origin: origin, fontSize: font.pointSize),
            color: field.textColor ?? state.color.nsColor,
            width: state.width.points
        )
        field.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        if annotation.isMeaningful { annotations.append(annotation) }
        needsDisplay = true
    }

    private func discardText() {
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Tooltips

    /// Shows the tooltip for whatever control the mouse is on. The first one
    /// waits a moment, as the system's do; moving along the bar to the next
    /// control swaps it straight away.
    func tipDidChange(immediately: Bool = false) {
        tipWork?.cancel()
        tipWork = nil
        guard let target = state.hoveredTip,
              let frame = state.tipFrames[target.id],
              let host = target.bar == .tools ? toolsBar : actionBar,
              !host.isHidden else {
            hideTip()
            return
        }
        let anchor = host.convert(frame, to: self)
        if immediately || tipLabel?.isHidden == false {
            showTip(target.text, at: anchor, bar: target.bar)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showTip(target.text, at: anchor, bar: target.bar) }
        }
        tipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func showTip(_ text: String, at anchor: CGRect, bar: CaptureBar) {
        let label: CaptureTipLabel
        if let tipLabel {
            label = tipLabel
        } else {
            label = CaptureTipLabel()
            tipLabel = label
        }
        // Always the topmost subview, above both bars.
        if label.superview !== self || subviews.last !== label {
            label.removeFromSuperview()
            addSubview(label)
        }
        label.text = CaptureTipLabel.attributed(text)
        let size = label.fittingSize2
        let edge: CGFloat = 4
        var origin: CGPoint
        switch bar {
        case .tools:
            // Beside the vertical bar, on the side away from the selection
            // when there is room.
            origin = CGPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
            if origin.x + size.width > bounds.maxX - edge { origin.x = anchor.minX - 10 - size.width }
        case .actions:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 8 - size.height)
            if origin.y < bounds.minY + edge { origin.y = anchor.maxY + 8 }
        }
        origin.x = min(max(origin.x, bounds.minX + edge), bounds.maxX - size.width - edge)
        origin.y = min(max(origin.y, bounds.minY + edge), bounds.maxY - size.height - edge)
        label.frame = CGRect(origin: origin, size: size).integral
        label.isHidden = false
    }

    private func hideTip() {
        tipWork?.cancel()
        tipWork = nil
        tipLabel?.isHidden = true
    }

    // MARK: - Toolbars

    private func setBarsHidden(_ hidden: Bool) {
        if hidden { hideTip() }
        if !hidden { installBarsIfNeeded() }
        toolsBar?.isHidden = hidden
        actionBar?.isHidden = hidden
        if !hidden { layoutBars() }
    }

    /// Recording shows its bar straight away, docked at the foot of the
    /// screen the way macOS's own ⇧⌘5 bar is, because choosing a window or
    /// an app starts there rather than with a drag.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if mode == .recording, window != nil, selection == nil { setBarsHidden(false) }
    }

    /// In recording mode an empty selection puts the bar back at the foot of
    /// the screen instead of hiding it.
    private func showDockedBarIfRecording() {
        if mode == .recording, selection == nil { setBarsHidden(false) }
    }

    private func installBarsIfNeeded() {
        guard actionBar == nil else { return }
        let perform: (CaptureAction) -> Void = { [weak self] action in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            if action == .undo {
                self.undo()
            } else {
                self.delegate?.overlay(self, perform: action)
            }
        }
        if mode == .screenshot {
            let tools = NSHostingView(rootView: CaptureToolsBar(state: state))
            tools.frame.size = tools.fittingSize
            addSubview(tools)
            toolsBar = tools
        }
        let actions = NSHostingView(rootView: CaptureActionBar(mode: mode, state: state, settings: AppSettings.shared, perform: perform))
        actions.frame.size = actions.fittingSize
        addSubview(actions)
        actionBar = actions
    }

    /// The tools sit to the right of the selection and the actions under it,
    /// as in the screenshot tools people already know; each moves to the other
    /// side, or inside, when the selection runs up against the screen's edge.
    private func layoutBars() {
        guard let selection else {
            if mode == .recording, let actionBar {
                let size = actionBar.fittingSize
                actionBar.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.minY + 90,
                                         width: size.width, height: size.height).integral
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        let margin: CGFloat = 8
        let edge: CGFloat = 4

        if let toolsBar {
            let size = toolsBar.fittingSize
            var x = selection.maxX + margin
            if x + size.width > bounds.maxX - edge { x = selection.minX - margin - size.width }
            if x < bounds.minX + edge { x = selection.maxX - margin - size.width }
            var y = selection.maxY - size.height
            y = min(max(y, bounds.minY + edge), bounds.maxY - size.height - edge)
            toolsBar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        }

        if let actionBar {
            let size = actionBar.fittingSize
            var x = selection.maxX - size.width
            x = min(max(x, bounds.minX + edge), bounds.maxX - size.width - edge)
            var y = selection.minY - margin - size.height
            if y < bounds.minY + edge { y = selection.maxY + margin }
            if y + size.height > bounds.maxY - edge { y = selection.minY + margin }
            actionBar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Output

    /// The selection with its marks, at the screen's full pixel resolution.
    func renderSelection() -> CGImage? {
        commitText()
        guard let snapshot, let selection else { return nil }
        let scale = CGFloat(snapshot.width) / bounds.width
        let width = Int((selection.width * scale).rounded())
        let height = Int((selection.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -selection.minX, y: -selection.minY)
        ctx.interpolationQuality = .none
        ctx.draw(snapshot, in: bounds)
        ctx.clip(to: selection)
        for annotation in annotations {
            annotation.draw(in: ctx, pixelated: annotation.isBlur ? pixelated : nil, imageBounds: bounds)
        }
        return ctx.makeImage()
    }
}

// MARK: - Tooltips

enum CaptureBar: String {
    case tools
    case actions

    var space: String { "captureBar.\(rawValue)" }
}

struct CaptureTipTarget: Equatable {
    let id: String
    let text: String
    let bar: CaptureBar
}

private struct CaptureTip: ViewModifier {
    let text: String
    let id: String
    let bar: CaptureBar
    let state: CaptureToolState

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named(bar.space))
                    Color.clear
                        .onAppear { state.tipFrames[id] = frame }
                        .onChange(of: frame) { _, new in state.tipFrames[id] = new }
                }
            )
            .onHover { inside in
                if inside {
                    state.hoveredTip = CaptureTipTarget(id: id, text: text, bar: bar)
                } else if state.hoveredTip?.id == id {
                    state.hoveredTip = nil
                }
            }
            .accessibilityLabel(text)
    }
}

private extension View {
    func captureTip(_ text: String, id: String, bar: CaptureBar, state: CaptureToolState) -> some View {
        modifier(CaptureTip(text: text, id: id, bar: bar, state: state))
    }
}

/// The tooltip itself: dark, small, and transparent to the mouse, so it never
/// swallows the click meant for whatever is under it.
final class CaptureTipLabel: NSView {
    var text = NSAttributedString() { didSet { needsDisplay = true } }

    static func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    var fittingSize2: CGSize {
        let size = text.size()
        return CGSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(white: 0.07, alpha: 0.96).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        text.draw(at: CGPoint(x: 8, y: 4))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Toolbars

/// A dark bar regardless of theme: it floats over arbitrary screen content,
/// and a light bar vanished against light windows in testing.
private struct CaptureBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(Color(white: 0.13).opacity(0.94), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
    }
}

private struct CaptureBarButton: View {
    let symbol: String
    let help: String
    let id: String
    let bar: CaptureBar
    let state: CaptureToolState
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            // A click puts the tooltip away, as the system's do; its text may
            // no longer be true (a switch that was just flipped).
            state.hoveredTip = nil
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(isEnabled ? 0.88 : 0.35))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor : (isHovered && isEnabled ? Color.white.opacity(0.14) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .captureTip(help, id: id, bar: bar, state: state)
        .onHover { isHovered = $0 }
    }
}

struct CaptureToolsBar: View {
    @Bindable var state: CaptureToolState

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                CaptureBarButton(
                    symbol: tool.symbol,
                    help: "\(tool.title) (\(String(tool.key).uppercased()))",
                    id: "tool.\(tool.rawValue)",
                    bar: .tools,
                    state: state,
                    isOn: state.tool == tool
                ) {
                    state.tool = state.tool == tool ? nil : tool
                }
            }
        }
        .modifier(CaptureBarBackground())
        .fixedSize()
        .coordinateSpace(name: CaptureBar.tools.space)
    }
}

struct CaptureActionBar: View {
    let mode: CaptureMode
    @Bindable var state: CaptureToolState
    @Bindable var settings: AppSettings
    let perform: (CaptureAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            switch mode {
            case .screenshot: screenshotControls
            case .recording: recordingControls
            }
        }
        .modifier(CaptureBarBackground())
        .fixedSize()
        .coordinateSpace(name: CaptureBar.actions.space)
    }

    private func button(_ symbol: String, _ help: String, id: String, isOn: Bool = false,
                        isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        CaptureBarButton(symbol: symbol, help: help, id: id, bar: .actions, state: state,
                         isOn: isOn, isEnabled: isEnabled, action: action)
    }

    @ViewBuilder
    private var screenshotControls: some View {
        HStack(spacing: 3) {
            ForEach(AnnotationColor.allCases) { color in
                Button { state.color = color; state.hoveredTip = nil } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(Color.white.opacity(color == .black ? 0.5 : 0.2)))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .background(Circle().strokeBorder(state.color == color ? Color.white : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.hoverLift(scale: 1.15))
                .captureTip(color.title, id: "color.\(color.rawValue)", bar: .actions, state: state)
            }
        }
        .padding(.horizontal, 4)

        divider

        ForEach(AnnotationWidth.allCases) { width in
            Button { state.width = width; state.hoveredTip = nil } label: {
                Circle()
                    .fill(Color.white)
                    .frame(width: width.points + 3, height: width.points + 3)
                    .frame(width: 24, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(state.width == width ? Color.white.opacity(0.2) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlate(.white, hover: 0.12, press: 0.22, padding: 0))
            .captureTip(width.title, id: "width.\(width.rawValue)", bar: .actions, state: state)
        }

        divider

        button("arrow.uturn.backward", L("Undo (⌘Z)"), id: "undo", isEnabled: state.canUndo) { perform(.undo) }

        divider

        button("text.viewfinder", L("Copy Text in Image"), id: "copyText") { perform(.copyText) }
        button("square.and.arrow.down", L("Save… (⌘S)"), id: "save") { perform(.save) }
        button("doc.on.doc", L("Copy (⌘C or ⏎)"), id: "copy") { perform(.copy) }
        button("xmark", L("Close (⎋)"), id: "close") { perform(.cancel) }
    }

    @ViewBuilder
    private var recordingControls: some View {
        // What to record, as video calls offer it: the whole screen, one
        // window, one app — or an area, by dragging across the screen.
        button("display", L("Record the whole screen"), id: "modeScreen") { perform(.recordScreen) }
        button("macwindow", L("Record a window…"), id: "modeWindow") { perform(.recordWindow) }
        button("app.dashed", L("Record an app…"), id: "modeApp") { perform(.recordApp) }

        divider

        button(
            settings.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash",
            settings.recordSystemAudio ? L("System audio: on") : L("System audio: off"),
            id: "audio",
            isOn: settings.recordSystemAudio
        ) { settings.recordSystemAudio.toggle() }

        button(
            settings.recordShowsPointer ? "cursorarrow" : "cursorarrow.slash",
            settings.recordShowsPointer ? L("Pointer: shown") : L("Pointer: hidden"),
            id: "pointer",
            isOn: settings.recordShowsPointer
        ) { settings.recordShowsPointer.toggle() }

        button(
            settings.recordCamera ? "video.fill" : "video.slash",
            settings.recordCamera ? L("Camera: on") : L("Camera: off"),
            id: "camera",
            isOn: settings.recordCamera
        ) { settings.recordCamera.toggle() }

        button(
            settings.recordMicrophone ? "mic.fill" : "mic.slash",
            settings.recordMicrophone ? L("Microphone: on") : L("Microphone: off"),
            id: "microphone",
            isOn: settings.recordMicrophone
        ) { settings.recordMicrophone.toggle() }

        button(
            "cursorarrow.click.2",
            settings.recordShowsClicks ? L("Clicks: shown") : L("Clicks: hidden"),
            id: "clicks",
            isOn: settings.recordShowsClicks
        ) { settings.recordShowsClicks.toggle() }

        divider

        Button { state.hoveredTip = nil; perform(.record) } label: {
            Label(L("Record"), systemImage: "record.circle")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverLift(scale: 1.03))
        .captureTip(L("Start recording (⏎)"), id: "record", bar: .actions, state: state)

        button("xmark", L("Close (⎋)"), id: "close") { perform(.cancel) }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 3)
    }
}

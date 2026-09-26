import AppKit
import SwiftUI

/// A borderless panel that takes clicks without activating CopyWell, so the
/// app being recorded or pasted into stays in front.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Toast

/// A short note near the bottom of the screen after a capture, so a shortcut
/// that did its work silently does not read as one that did nothing.
@MainActor
enum CaptureToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let view = CaptureToastView(message: message, symbol: symbol, actionTitle: actionTitle) {
            action?()
            dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 72)

        let panel = FloatingPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = action == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        let seconds: UInt64 = action == nil ? 2 : 6
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    static func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

private struct CaptureToastView: View {
    let message: String
    let symbol: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.hoverLink)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.13).opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

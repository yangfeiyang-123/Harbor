import SwiftUI
import AppKit

extension View {
    func compactHint(_ title: String, detail: String = "", enabled: Bool = true, edge: NSRectEdge = .maxX) -> some View {
        modifier(CompactHint(title: title, detail: detail, enabled: enabled, edge: edge))
    }
}

private struct CompactHint: ViewModifier {
    let title: String
    let detail: String
    let enabled: Bool
    let edge: NSRectEdge
    func body(content: Content) -> some View {
        content
            .background { if enabled { HintAnchor(title: title, detail: detail, edge: edge) } }
    }
}

private struct HintAnchor: NSViewRepresentable {
    let title: String
    let detail: String
    let edge: NSRectEdge
    func makeNSView(context: Context) -> HintAnchorView { HintAnchorView() }
    func updateNSView(_ view: HintAnchorView, context: Context) { view.title = title; view.detail = detail; view.edge = edge }
    static func dismantleNSView(_ view: HintAnchorView, coordinator: ()) { view.cancel() }
}

/// A non-activating, click-through hint avoids stealing focus from a live terminal or editor.
private final class HintAnchorView: NSView {
    var title = ""
    var detail = ""
    var edge = NSRectEdge.maxX
    private var pending: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    private var panel: NSPanel?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        cancel()
        let work = DispatchWorkItem { [weak self] in self?.show() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    override func mouseExited(with event: NSEvent) { cancel() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { cancel(); super.viewWillMove(toWindow: newWindow) }
    func cancel() {
        pending?.cancel(); pending = nil
        panel?.orderOut(nil); panel = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    private func show() {
        guard let window, window.isKeyWindow, !title.isEmpty else { return }
        let content = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(3)
            if !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundStyle(Color.harborMuted).lineLimit(3) }
        }.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: 340, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true).foregroundStyle(Color.harborForeground).harborGlass(radius: 11))
        let size = content.fittingSize
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        var origin = edge == .maxX ? NSPoint(x: anchor.maxX + 9, y: anchor.midY - size.height / 2)
            : NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 9)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        let hint = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hint.isOpaque = false; hint.backgroundColor = .clear; hint.hasShadow = true
        hint.level = .popUpMenu; hint.hidesOnDeactivate = true; hint.ignoresMouseEvents = true
        hint.appearance = window.effectiveAppearance; hint.contentView = content
        hint.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        hint.orderFront(nil); panel = hint
        if hint.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; hint.animator().alphaValue = 1 }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in self?.cancel(); return event }
    }
}

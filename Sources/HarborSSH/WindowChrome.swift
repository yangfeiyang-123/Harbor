import SwiftUI
import AppKit

struct WindowChrome: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> ChromeAnchor { ChromeAnchor() }
    func updateNSView(_ view: ChromeAnchor, context: Context) { view.dark = colorScheme == .dark; view.configure() }
    final class ChromeAnchor: NSView {
        var dark = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = HarborTheme.native("titleBar.activeBackground", dark: dark)
        }
    }
}
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragArea { DragArea() }
    func updateNSView(_ view: DragArea, context: Context) {}
    final class DragArea: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

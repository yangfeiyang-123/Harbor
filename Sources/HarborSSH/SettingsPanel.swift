import SwiftUI
import AppKit

/// Settings as a panel over the window they were asked for in: dimmed surroundings, Esc or a
/// click outside to leave, and a button to fill the window while there is a lot to read.
struct SettingsPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settingsMaximized") private var maximized = false
    @AppStorage(HarborMotion.preferenceKey) private var motion = HarborMotion.Level.full.rawValue
    private var motionLevel: HarborMotion.Level { HarborMotion.level(motion, reduceMotion: reduceMotion) }

    var body: some View {
        GeometryReader { geometry in
            // Under Harbor's bar, and under the tab bar when the window has tabs.
            let top = store.windowTop.contentTop
            let width = maximized ? geometry.size.width - 16 : min(1040, geometry.size.width - 56)
            let height = maximized ? geometry.size.height - top - 8 : min(700, geometry.size.height - top - 40)
            ZStack(alignment: .top) {
                Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture(perform: close)
                    .accessibilityLabel("Close Settings").accessibilityAddTraits(.isButton)
                SettingsView(maximized: $maximized, close: close)
                    .frame(width: max(width, 600), height: max(height, 380))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.harborBorder, lineWidth: 1))
                    // The shadow is cast from the panel's outline (HarborPanelShadow). On the panel
                    // itself, every blink of the preview's cursor would redraw the whole panel to cast it again.
                    .harborPanelGround(Color.harborBackground, cornerRadius: 12, shadow: 0.35, radius: 28, y: 12)
                    .padding(.top, maximized ? top : top + max(0, (geometry.size.height - top - height) / 2 - 6))
                    .animation(motionLevel == .full ? Animation.spring(response: 0.3, dampingFraction: 0.9) : HarborMotion.fade(level: motionLevel), value: maximized)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(SettingsPanelKeys(close: close))
        .accessibilityIdentifier("settings-panel")
    }
    private func close() { store.settingsVisible = false }
}

/// Esc leaves the panel wherever the keyboard is, and the view that had the keyboard
/// before the panel opened (usually the editor) gets it back afterwards.
private struct SettingsPanelKeys: NSViewRepresentable {
    let close: () -> Void
    func makeNSView(context: Context) -> Monitor { Monitor(close: close) }
    func updateNSView(_ view: Monitor, context: Context) { view.close = close }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.finish() }

    final class Monitor: NSView {
        var close: () -> Void
        private var monitor: Any?
        private weak var previous: NSResponder?
        private weak var host: NSWindow?
        init(close: @escaping () -> Void) { self.close = close; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, monitor == nil else { return }
            host = window; previous = window.firstResponder
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.host, event.keyCode == 53,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [.capsLock, .numericPad, .function]) else { return event }
                // A menu or a field's completion list takes Esc before the panel does.
                if let editor = self.host?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                self.close(); return nil
            }
        }
        func finish() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let host, let previous, (previous as? NSView)?.window === host { host.makeFirstResponder(previous) }
        }
    }
}

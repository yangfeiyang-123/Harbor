import SwiftUI
import AppKit

extension Notification.Name {
    /// "Always Show Tab Bar" was switched.
    static let harborTabBarPolicyChanged = Notification.Name("harbor.tabbar.policy.changed")
}

enum WorkbenchWindowMetrics {
    static let titlebarHeight: CGFloat = 32
    static let trafficLightInset: CGFloat = 84
    static let controlSize: CGFloat = 26
}

/// What the system draws over the top of a workbench window. Alone, a window has only its title
/// row, and Harbor's own bar fills it. With tabs, the tab bar comes under that row; in full screen
/// the title row is off screen and the tab bar is the first thing on it. The content reaches the
/// top of the window in every case, so it has to leave that room itself.
struct WindowTop: Equatable {
    var titleRow: CGFloat = WorkbenchWindowMetrics.titlebarHeight
    var tabBar: CGFloat = 0
    var fullScreen = false
    /// A tab bar that is only on screen while the pointer is at the top of the window. It lies
    /// over the page for that moment and takes no room, so nothing under it is laid out again.
    var peek: CGFloat = 0
    init() {}
    /// `covered` is the height the system reports as taken at the top; `titlebar` the height of a plain title row.
    init(covered: CGFloat, titlebar: CGFloat, tabs: Bool, fullScreen: Bool) {
        self.fullScreen = fullScreen
        titleRow = fullScreen ? 0 : titlebar
        tabBar = tabs ? max(0, covered - titleRow) : 0
    }
    /// Left free above Harbor's bar: a tab bar that is at the very top.
    var aboveBar: CGFloat { tabBar > 0 && fullScreen ? tabBar : 0 }
    /// Harbor's bar is the title row while there is one beside the tab bar.
    var barHeight: CGFloat { tabBar > 0 && !fullScreen ? titleRow : WorkbenchWindowMetrics.titlebarHeight }
    /// Left free under Harbor's bar: a tab bar that sits under the title row.
    var belowBar: CGFloat { tabBar > 0 && !fullScreen ? tabBar : 0 }
    /// The bar starts after the window's close, minimize and zoom buttons only while it shares their row.
    var barLeading: CGFloat { aboveBar > 0 || fullScreen ? 12 : WorkbenchWindowMetrics.trafficLightInset }
    /// Where the page under Harbor's bar begins.
    var contentTop: CGFloat { aboveBar + barHeight + belowBar }
    /// For a page without that bar: everything the system covers once there are tabs.
    var covered: CGFloat { tabBar > 0 ? titleRow + tabBar : 0 }
}

/// Hover changes only opacity and hit testing. The workbench keeps its full
/// geometry while menus/popovers remain usable outside the title-bar bounds.
@MainActor final class WorkbenchToolbarVisibility: ObservableObject {
    @Published private(set) var revealed = false
    private var hovered = false
    private var popoverPresented = false
    private var trackingMenus = 0
    private var hideTask: Task<Void, Never>?

    func setHovered(_ value: Bool) {
        hovered = value
        update()
    }
    func setPopoverPresented(_ value: Bool) {
        popoverPresented = value
        update()
    }
    func menuTracking(_ opening: Bool) {
        // Menus elsewhere in the application must not reveal this toolbar.
        if opening {
            guard revealed else { return }
            trackingMenus += 1
        } else { trackingMenus = max(0, trackingMenus - 1) }
        update()
    }
    func reset() {
        hideTask?.cancel(); hideTask = nil
        hovered = false; popoverPresented = false; trackingMenus = 0; revealed = false
    }
    private func update() {
        hideTask?.cancel(); hideTask = nil
        if hovered || popoverPresented || trackingMenus > 0 { revealed = true; return }
        guard revealed else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, let self, !hovered, !popoverPresented, trackingMenus == 0 else { return }
            revealed = false; hideTask = nil
        }
    }
}

struct WindowChrome: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    /// Told what the system covers at the top whenever that changes (tabs, full screen).
    var top: (WindowTop) -> Void = { _ in }
    func makeNSView(context: Context) -> ChromeAnchor { ChromeAnchor() }
    func updateNSView(_ view: ChromeAnchor, context: Context) { view.dark = colorScheme == .dark; view.selection = appearance; view.report = top; view.configure() }
    final class ChromeAnchor: NSView {
        var dark = false
        var selection = "system"
        var report: (WindowTop) -> Void = { _ in }
        private var layoutObservation: NSKeyValueObservation?
        private var observers: [NSObjectProtocol] = []
        private var last: WindowTop?
        /// The pointer is at the top of a window whose tab bar is otherwise put away.
        private var peeking = false
        private var putAway: DispatchWorkItem?
        private var strip: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); configure()
            layoutObservation = nil; observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); last = nil
            guard let window else { return }
            // The tab bar and full screen both change the layout rectangle; the notifications cover
            // a window that was not the selected tab while that happened.
            layoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.measure() } }
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: .harborTabBarPolicyChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.measure() }
            })
            measure()
        }

        // The tab bar. With several windows gathered as tabs it took a row of every window all
        // the time. It is now put away and comes when the pointer goes to the top: in full screen
        // with the menu bar (the system does that for a bar whose full-screen height is nothing),
        // in a window while the pointer is in the title row or on the bar itself.
        static let alwaysShowKey = "alwaysShowTabBar"
        private var tabBar: NSTitlebarAccessoryViewController? {
            guard let window, window.tabGroup?.isTabBarVisible == true else { return nil }
            return window.titlebarAccessoryViewControllers.first { controller in
                controller.view.subviews.contains { String(describing: type(of: $0)) == "NSTabBar" }
            }
        }
        /// Applies the policy and says whether the bar is being kept out of the layout.
        private func arrangeTabBar() -> (overlaid: Bool, height: CGFloat) {
            guard let window, let bar = tabBar else { setStrip(nil); return (false, 0) }
            let hides = !UserDefaults.standard.bool(forKey: Self.alwaysShowKey)
            let height = bar.view.frame.height > 0 ? bar.view.frame.height : 36
            let full = window.styleMask.contains(.fullScreen)
            let minimum: CGFloat = hides ? 0 : height
            if bar.fullScreenMinHeight != minimum { bar.fullScreenMinHeight = minimum }
            let hidden = hides && !full && !peeking
            if bar.isHidden != hidden {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    bar.animator().isHidden = hidden
                }
            }
            guard hides, !full else { setStrip(nil); return (false, height) }
            // The title row brings it; once it is there, the bar itself keeps it.
            let titlebar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
            setStrip(titlebar + (peeking ? height + 8 : 0))
            return (true, height)
        }
        private func setStrip(_ height: CGFloat?) {
            if let strip { removeTrackingArea(strip); self.strip = nil }
            guard let height, let window else { if peeking { peeking = false }; return }
            let rect = convert(CGRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height), from: nil).intersection(bounds)
            guard !rect.isEmpty else { return }
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
            addTrackingArea(area); strip = area
        }
        override func updateTrackingAreas() { super.updateTrackingAreas(); measure() }
        override func mouseEntered(with event: NSEvent) {
            putAway?.cancel(); putAway = nil
            if !peeking { peeking = true; measure() }
        }
        override func mouseExited(with event: NSEvent) {
            putAway?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.peeking else { return }
                    // Still over it (a tab is being dragged, or its menu is open): leave it.
                    if let window = self.window, let strip = self.strip, strip.rect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) { return }
                    self.peeking = false; self.measure()
                }
            }
            putAway = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        func measure() {
            guard let window else { return }
            let bar = arrangeTabBar()
            let titlebar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
            var top = WindowTop(covered: bar.overlaid ? titlebar : window.frame.height - window.contentLayoutRect.maxY, titlebar: titlebar,
                                tabs: !bar.overlaid && window.tabGroup?.isTabBarVisible == true, fullScreen: window.styleMask.contains(.fullScreen))
            if bar.overlaid, peeking { top.peek = bar.height }
            guard top != last else { return }
            last = top
            // Not during a view update: this changes what the window's views lay out.
            DispatchQueue.main.async { [report] in report(top) }
        }
        func configure() {
            guard let window else { return }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
            let background = HarborTheme.native("titleBar.activeBackground", dark: dark, selection: selection)
            if window.backgroundColor != background { window.backgroundColor = background }
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

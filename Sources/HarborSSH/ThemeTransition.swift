import AppKit
import QuartzCore

/// A change of theme, seen as one change: every Harbor window dissolves from the old colors into
/// the new ones.
///
/// Changed at once, a theme repainted the window part by part: the native parts each as they were
/// drawn again, and the editor only once Code-OSS had put its new theme on, which on a distant
/// server is a good part of a second later; meanwhile the window showed two themes at once. Now
/// the moment the stored theme changes, before anything has been drawn with the new colors, each
/// window on screen is given a dissolve: Core Animation shows the window as it was and fades it
/// into the window as it is drawn next, editor and all. The editor, whose colors change later,
/// holds a picture of itself until they are drawn and then dissolves the same way
/// (WorkbenchStage.dissolve).
@MainActor enum ThemeTransition {
    /// Seconds for the old colors to give way to the new ones. Motion Off changes them at once;
    /// Subtle (and Reduce Motion) keeps a short dissolve, since nothing moves in one.
    static func duration(_ level: HarborMotion.Level) -> Double {
        switch level { case .full: return 0.34; case .subtle: return 0.16; case .off: return 0 }
    }
    // Core Animation stores CATransition under this canonical key, even when add
    // receives a different one. Use the same key for adding and inspecting it.
    static let key = kCATransition
    private static var observer: AppearanceObserver?

    /// Watches the stored theme from launch on, so that whatever changes it (Settings, the
    /// editor's own settings, a menu) is seen before the new colors are drawn.
    static func install(_ defaults: UserDefaults = .standard) {
        guard observer == nil else { return }
        observer = AppearanceObserver(defaults: defaults)
    }
    /// The windows that are on screen dissolve into what they show once this turn of the run loop
    /// has drawn them.
    static func begin(level: HarborMotion.Level = HarborMotion.current, windows: [NSWindow]? = nil) {
        let seconds = duration(level)
        guard seconds > 0 else { return }
        for window in windows ?? NSApp.windows.filter(\.isVisible) {
            guard let layer = window.contentView?.layer else { continue }
            let dissolve = CATransition()
            dissolve.type = .fade
            dissolve.duration = seconds
            dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(dissolve, forKey: key)
        }
    }
}

/// Told by UserDefaults, as the value is set and before anything is drawn with it, that the
/// stored theme has changed.
private final class AppearanceObserver: NSObject {
    let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        defaults.addObserver(self, forKeyPath: "appearance", options: [.old, .new], context: nil)
    }
    deinit { defaults.removeObserver(self, forKeyPath: "appearance") }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "appearance", (change?[.oldKey] as? String) != (change?[.newKey] as? String) else { return }
        if Thread.isMainThread { MainActor.assumeIsolated { ThemeTransition.begin() } }
        else { Task { @MainActor in ThemeTransition.begin() } }
    }
}

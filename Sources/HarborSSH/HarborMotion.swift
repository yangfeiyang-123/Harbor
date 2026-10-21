import SwiftUI
import AppKit

/// One motion vocabulary for native surfaces and the embedded workbench:
/// short distances, a long ease-out, and nothing that resizes a terminal grid.
/// "Reduce Motion" in macOS always wins over the stored preference.
enum HarborMotion {
    enum Level: String, CaseIterable { case full, subtle, off }
    static let preferenceKey = "motionLevel"
    static let levels = Level.allCases.map(\.rawValue)

    static func level(_ stored: String, reduceMotion: Bool) -> Level {
        let value = Level(rawValue: stored) ?? .full
        return reduceMotion && value == .full ? .subtle : value
    }
    static var current: Level {
        level(UserDefaults.standard.string(forKey: preferenceKey) ?? Level.full.rawValue,
              reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    /// The curve used on anthropic.com-style reveals: fast start, long settle.
    static func ease(_ duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
    static let quick = 0.18, standard = 0.34, slow = 0.62
    static func animation(_ duration: Double = standard, level: Level = current) -> Animation? {
        switch level {
        case .full: return ease(duration)
        case .subtle: return .easeOut(duration: min(duration, 0.16))
        case .off: return nil
        }
    }
    /// Distance in points an element travels while it fades in.
    static func travel(_ points: Double, level: Level) -> Double { level == .full ? points : 0 }

    /// Feedback on a control. Hover keeps Harbor's own curve (fast start, long settle); the
    /// rest is timed after Anthropic's "MCP Apps for Claude" UI kit: an icon button changes at
    /// once, a checkbox answers in 50 ms and a radio in 100 ms (ease-out), a switch slides in
    /// 150 ms on the standard curve, and a status line dissolves into the next in 100 ms.
    enum Feedback { case hover, iconHover, check, select, toggle, crossfade }
    static func feedback(_ kind: Feedback, level: Level = current) -> Animation? {
        guard level != .off else { return nil }
        switch kind {
        case .hover: return animation(quick, level: level)
        case .iconHover: return nil
        case .check: return .easeOut(duration: 0.05)
        case .select: return .easeOut(duration: 0.10)
        case .toggle: return .timingCurve(0.4, 0, 0.2, 1, duration: 0.15)
        case .crossfade: return .easeOut(duration: 0.10)
        }
    }
    /// A short fade for something that appears over a page (a panel, a note, a drop target).
    /// Off turns it off; Reduce Motion keeps it, since a fade does not move anything.
    static func fade(_ duration: Double = 0.14, level: Level = current) -> Animation? {
        level == .off ? nil : .easeOut(duration: duration)
    }
}

/// Fades content in on first appearance, optionally rising a few points and
/// staggered by `index`. It never animates on removal, so switching pages stays
/// immediate and a hidden web view is not kept alive for an exit transition.
/// `after` places it on a page's own timeline, and content that is not `ready`
/// (its data is still being read) waits and then takes its turn.
private struct HarborReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var stored = HarborMotion.Level.full.rawValue
    let index: Int
    let distance: Double
    let trigger: AnyHashable?
    var after = 0.0
    var ready = true
    @State private var shown = false
    @State private var appeared = Date()
    func body(content: Content) -> some View {
        let level = HarborMotion.level(stored, reduceMotion: reduceMotion)
        content
            .opacity(shown || level == .off && ready ? 1 : 0)
            .offset(y: shown ? 0 : HarborMotion.travel(distance, level: level))
            .onAppear { appeared = Date(); if ready { play(level) } }
            .onChange(of: ready) { _, ready in if ready, !shown { play(level) } }
            .onChange(of: trigger) { _, _ in shown = false; appeared = Date(); if ready { play(level) } }
    }
    private func play(_ level: HarborMotion.Level) {
        guard level != .off else { shown = true; return }
        // Its place on the timeline counts from when the page appeared, so content that had to
        // wait for its data does not wait a second time.
        let turn = after + min(Double(index) * 0.045, 0.6) - Date().timeIntervalSince(appeared)
        let delay = level == .full ? max(0, turn) : 0
        withAnimation(HarborMotion.animation(HarborMotion.slow, level: level)?.delay(delay)) { shown = true }
    }
}

extension View {
    /// Fade (and rise) in when the view appears. `index` staggers siblings;
    /// changing `trigger` replays the entrance.
    func harborReveal(_ index: Int = 0, distance: Double = 10, trigger: AnyHashable? = nil, after: Double = 0, ready: Bool = true) -> some View {
        modifier(HarborReveal(index: index, distance: distance, trigger: trigger, after: after, ready: ready))
    }
}

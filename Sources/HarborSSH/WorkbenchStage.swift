import AppKit
import SwiftUI
import WebKit

/// Where a window shows its editors. Every folder's editor is a web view of its own, and a web
/// view that is put into a window needs a moment before it has drawn itself. For that moment the
/// window showed nothing, so each switch between two open folders was a white flash and a hard
/// cut. The stage keeps the editor that is leaving on top until the one arriving has drawn, and
/// then lets it fade: one editor turns into the other.
final class WorkbenchStage: NSView {
    private(set) weak var current: WKWebView?
    private var leaving: [WKWebView] = []
    /// Seconds for one editor to give way to the next.
    static func fade(_ level: HarborMotion.Level) -> Double {
        switch level { case .full: return 0.24; case .subtle: return 0.12; case .off: return 0 }
    }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    // Clicks go to the editor that is staying, never to the one on its way out.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let current, current.superview === self else { return nil }
        return current.hitTest(convert(point, from: superview))
    }

    func show(_ web: WKWebView?, motion: HarborMotion.Level) {
        guard web !== current else { return }
        // The editor that is leaving is not kept as a picture; the one arriving is shown live.
        dropCover()
        let outgoing = current
        current = web
        var returned = false
        if let web {
            if let index = leaving.firstIndex(where: { $0 === web }) {
                // It was on its way out and is wanted again: it stays, as it is.
                leaving.remove(at: index); returned = true
                web.layer?.removeAllAnimations(); web.alphaValue = 1
            }
            web.frame = bounds; web.autoresizingMask = [.width, .height]
            // Under whatever is showing, so it draws itself out of sight.
            if web.superview !== self { addSubview(web, positioned: .below, relativeTo: nil) }
        }
        guard let outgoing, outgoing.superview === self else { return }
        // Nobody is looking (the page is not in a window), or the one that came back is already on top.
        guard window != nil, !returned else { outgoing.removeFromSuperview(); outgoing.alphaValue = 1; return }
        leaving.append(outgoing)
        let duration = Self.fade(motion)
        Task { @MainActor [weak self] in
            if let web { await Self.drawn(web) }
            guard let self, self.leaving.contains(where: { $0 === outgoing }) else { return }
            guard duration > 0 else { self.retire(outgoing); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                outgoing.animator().alphaValue = 0
            }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.retire(outgoing) } })
        }
    }
    /// While a panel lies over the whole window (Folders in Windows, Settings), the editor under it
    /// is a picture of itself and its web view is hidden. Live, the page with every layer Code-OSS
    /// keeps was put together again with the panel for each frame in which anything on the panel
    /// moved, and a list there scrolled at a few frames a second. The picture is taken away once
    /// the panel has gone and the page has drawn again, so that nothing flashes.
    private var cover: NSImageView?
    private weak var hiddenWeb: WKWebView?
    private var covered = false
    func setCovered(_ value: Bool) {
        guard value != covered else { return }
        covered = value
        if value { coverEditor() } else { uncoverEditor() }
    }
    private func coverEditor() {
        guard let web = current, web.superview === self, window != nil, !web.isHidden, bounds.width > 1, bounds.height > 1 else { return }
        web.takeSnapshot(with: nil) { [weak self, weak web] image, _ in
            MainActor.assumeIsolated {
                guard let self, self.covered, self.cover == nil, let web, web === self.current, web.superview === self, let image else { return }
                let picture = NSImageView(frame: self.bounds)
                picture.image = image; picture.imageScaling = .scaleAxesIndependently
                picture.autoresizingMask = [.width, .height]
                picture.setAccessibilityElement(false)
                self.addSubview(picture, positioned: .above, relativeTo: web)
                self.cover = picture
                web.isHidden = true; self.hiddenWeb = web
            }
        }
    }
    private func uncoverEditor() {
        hiddenWeb?.isHidden = false; hiddenWeb = nil
        guard let picture = cover else { return }
        cover = nil
        Task { @MainActor [weak self] in
            if let web = self?.current, web.window != nil { await Self.drawn(web) }
            picture.removeFromSuperview()
        }
    }
    /// At once, without waiting for the page to draw.
    private func dropCover() {
        hiddenWeb?.isHidden = false; hiddenWeb = nil
        cover?.removeFromSuperview(); cover = nil
        dissolving?.removeFromSuperview(); dissolving = nil
        stopWatchingInput()
    }

    /// A new theme for the editor on stage. Code-OSS puts it on a moment after the rest of the
    /// window has its new colors (the setting goes to the server and back), and repaints itself as
    /// it goes. So a picture of the editor as it is lies over it while `change` runs, and once the
    /// page has drawn the new colors the picture dissolves into it, as the window did
    /// (ThemeTransition). Under a panel, where the editor is a picture already, the page is shown
    /// under that picture for the change and becomes a picture again afterwards, in its new colors.
    ///
    /// The picture is still while the editor under it goes on: what is typed or clicked reaches the
    /// editor, unseen. On a slow server the change took many seconds, and the editor looked stuck
    /// in its old colors all that time. So the picture never stays longer than `holdLimit`, and
    /// goes at once when the editor is used (a click, a key, the wheel).
    private var dissolving: NSImageView?
    private var changing = 0
    private var inputMonitor: Any?
    static let holdLimit = 1.2
    func dissolve(_ level: HarborMotion.Level = HarborMotion.current, during change: () async -> Void) async {
        changing += 1
        // A change that comes while another is under way goes under the same picture.
        if changing == 1, dissolving == nil, level != .off {
            await holdEditor()
            if let picture = dissolving {
                watchInput(releasing: picture, level)
                Task { @MainActor [weak self, weak picture] in
                    try? await Task.sleep(for: .seconds(WorkbenchStage.holdLimit))
                    if let self, let picture { self.release(picture, level) }
                }
            }
        }
        await change()
        changing -= 1
        guard changing == 0 else { return }
        if let web = current, web.window != nil, !web.isHidden { await Self.drawn(web) }
        if let picture = dissolving { release(picture, level) }
        // Let go of early, under a panel: a picture again, now that the new colors are on.
        else if covered, cover == nil, current?.isHidden == false { coverEditor() }
    }
    private func holdEditor() async {
        guard let web = current, web.superview === self, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        if let picture = cover, hiddenWeb === web {
            // Under a panel: the picture that is there already holds it, and the page is shown under it.
            cover = nil; hiddenWeb = nil; web.isHidden = false
            dissolving = picture
            return
        }
        guard !web.isHidden, cover == nil else { return }
        // A page that is slow to answer is not waited for: the change is made without a picture.
        let image: NSImage? = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
            var resumed = false
            let finish = { (image: NSImage?) in if !resumed { resumed = true; done.resume(returning: image) } }
            web.takeSnapshot(with: nil) { image, _ in finish(image) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish(nil) }
        }
        guard let image, web === current, web.superview === self, !web.isHidden, cover == nil, dissolving == nil else { return }
        let picture = NSImageView(frame: bounds)
        picture.image = image; picture.imageScaling = .scaleAxesIndependently
        picture.autoresizingMask = [.width, .height]
        picture.setAccessibilityElement(false)
        addSubview(picture, positioned: .above, relativeTo: web)
        dissolving = picture
    }
    /// The picture dissolves into the editor: once the change is done, at the hold's limit, or at
    /// once (quickly) when the editor is used. Whichever comes first; the others find it gone.
    private func release(_ picture: NSImageView, _ level: HarborMotion.Level, quickly: Bool = false) {
        guard dissolving === picture else { return }
        dissolving = nil
        stopWatchingInput()
        let duration = ThemeTransition.duration(level)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = quickly ? min(duration, 0.12) : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            picture.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                picture.removeFromSuperview()
                // Still under a panel, with the change done: a picture again, of the new colors.
                // (Let go of before it was done, the change itself does this when it is.)
                if let self, self.covered, self.cover == nil, self.changing == 0, self.dissolving == nil { self.coverEditor() }
            }
        })
    }
    private func watchInput(releasing picture: NSImageView, _ level: HarborMotion.Level) {
        stopWatchingInput()
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self, weak picture] event in
            MainActor.assumeIsolated {
                if let self, let picture, event.window === self.window { self.release(picture, level, quickly: true) }
            }
            return event
        }
    }
    private func stopWatchingInput() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func retire(_ web: WKWebView) {
        // One that was asked for again in the meantime has left the list and stays.
        guard let index = leaving.firstIndex(where: { $0 === web }) else { return }
        leaving.remove(at: index)
        if web !== current { web.removeFromSuperview() }
        web.alphaValue = 1
    }

    /// The page has painted since it was put in the window (two of its animation frames have run),
    /// or enough time has passed that waiting longer would be worse than what it hides.
    static func drawn(_ web: WKWebView) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = { if !resumed { resumed = true; done.resume() } }
            web.callAsyncJavaScript("await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(() => done(true))))",
                                    arguments: [:], in: nil, in: .defaultClient) { _ in finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { finish() }
        }
        // What the page painted still has to reach the window.
        try? await Task.sleep(for: .milliseconds(34))
    }

    /// Coming back to the workspace page (from the start page, a terminal): the editor was out of
    /// the window, so it fades in once it has drawn instead of flashing in.
    var entrance = HarborMotion.Level.full
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let current, current.superview === self, entrance != .off else { alphaValue = 1; return }
        alphaValue = 0
        let duration = Self.fade(entrance)
        Task { @MainActor [weak self] in
            await Self.drawn(current)
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }
}

/// The stage in the window's page. It is one view for as long as the workspace page is shown,
/// whichever folder that is, so that a switch is a change on the stage and not a new view.
struct WorkbenchStageLayer: View {
    let stage: WorkbenchStage
    @ObservedObject var session: CodeWorkbenchSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var stored = HarborMotion.Level.full.rawValue
    var body: some View {
        Host(stage: stage, web: session.web, motion: HarborMotion.level(stored, reduceMotion: reduceMotion))
            .opacity(session.layoutOpacity)
    }
    private struct Host: NSViewRepresentable {
        let stage: WorkbenchStage
        let web: WKWebView?
        let motion: HarborMotion.Level
        func makeNSView(context: Context) -> WorkbenchStage { stage.entrance = motion; return stage }
        func updateNSView(_ stage: WorkbenchStage, context: Context) { stage.entrance = motion; stage.show(web, motion: motion) }
    }
}

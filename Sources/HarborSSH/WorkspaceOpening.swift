import SwiftUI
import HarborCore

/// "RLptBench · 4Rtx4090 · Grail": the window's own name if it has one, the server a workspace is
/// on, then its folder. One view draws it at every size, so the large title of a workspace that
/// is opening and the quiet one in the window's bar are the same thing at two moments.
/// `progress` 0 is the large one.
struct WorkspaceTitle: View, Animatable {
    /// The name the window was given. It leads, a little larger and firmer than what follows.
    var window: String? = nil
    var server: String
    var folder: String
    var progress: Double = 1
    var muted = WorkspaceTheme.muted
    var strong = WorkspaceTheme.foreground
    static let large = 26.0, small = 12.0
    /// How much larger the window's name is set than the server and folder after it.
    static let lead = 13.0 / 12.0
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        let size = Self.large + (Self.small - Self.large) * progress
        HStack(alignment: .firstTextBaseline, spacing: size * 0.52) {
            if let window, !window.isEmpty {
                Text(window).font(.system(size: size * Self.lead, weight: .semibold)).foregroundStyle(strong.opacity(0.88))
                dot(size)
            }
            Text(server).foregroundStyle(muted)
            dot(size)
            // The folder is the subject while it opens and settles into the bar's quiet tone.
            ZStack {
                Text(folder).foregroundStyle(muted)
                Text(folder).foregroundStyle(strong).opacity(1 - progress)
            }
        }
        .font(.system(size: size, weight: .medium)).lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel([window, server, folder].compactMap { $0 }.joined(separator: ", "))
    }
    /// What stands between the parts: a small round dot at the middle of the letters' height, with
    /// the same room on either side. (The "·" of the typeface is a thin mark that sits low and
    /// off center between two words.)
    private func dot(_ size: Double) -> some View {
        let diameter = max(2.5, size * 0.24)
        return Circle().fill(muted.opacity(0.6)).frame(width: diameter, height: diameter)
            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + size * 0.27 }
    }
}

/// What a workspace shows while its editor starts: the server and folder being opened, and
/// under them what is happening. When the editor is ready the page fades away over it and the
/// title travels up into the window's bar, where it stays. There is no second screen to cut to.
struct WorkspaceOpening: View {
    @ObservedObject var session: CodeWorkbenchSession
    @ObservedObject var workspace: FileWorkspace
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var stored = HarborMotion.Level.full.rawValue
    let top: WindowTop
    /// 0 while opening, 1 once the title has reached the bar.
    @State private var landing = 1.0
    @State private var covering = false
    /// The title is on screen. It fades in, unless the window was already naming the folder it was given.
    @State private var titled = false
    /// What was happening when the editor became ready; the page leaves with the words it had.
    @State private var phase = ""
    /// A thing that travels sets off gently and arrives gently, unlike a reveal, which starts at once.
    private static let flight = Animation.timingCurve(0.3, 0, 0.1, 1, duration: 0.58)

    private var opening: Bool { !session.ready && !session.revealed && session.error == nil }
    private var level: HarborMotion.Level { HarborMotion.level(stored, reduceMotion: reduceMotion) }
    /// The title ends in the window's bar, where the same title stands.
    private var travels: Bool { level == .full }

    /// Where the large title sits: a little above the middle of the page under the bar.
    static func titleCenter(height: Double, top: WindowTop) -> Double { top.contentTop + (height - top.contentTop) * 0.40 }

    var body: some View {
        GeometryReader { geometry in
            let barY = top.aboveBar + top.barHeight / 2, pageTop = top.contentTop
            let centerY = Self.titleCenter(height: geometry.size.height, top: top)
            let fade = max(0, 1 - landing * 2.2)
            ZStack {
                if covering {
                    // Over the editor until it has drawn itself, so its half-loaded states are never seen.
                    WorkspaceTheme.background.opacity((1 - landing) * (titled ? 1 : 0))
                        .frame(height: max(0, geometry.size.height - pageTop)).position(x: geometry.size.width / 2, y: pageTop + (geometry.size.height - pageTop) / 2)
                        .contentShape(Rectangle())
                    status.frame(width: min(520, geometry.size.width - 80)).opacity(fade)
                        .position(x: geometry.size.width / 2, y: centerY + 78)
                    WorkspaceTitle(window: store.windowName, server: workspace.profile?.name ?? LocalMachine.name, folder: workspace.directoryTitle, progress: travels ? landing : 0)
                        .frame(maxWidth: geometry.size.width - 220)
                        .opacity((travels ? 1 : fade) * (titled ? 1 : 0))
                        .position(x: geometry.size.width / 2, y: travels ? centerY + (barY - centerY) * landing : centerY)
                        .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(covering && landing < 0.5)
        .onAppear {
            covering = opening; landing = opening ? 0 : 1; session.titleInFlight = opening && travels; phase = session.phase
            // A window that was handed this folder has been showing its name already; this page takes over from that note.
            if store.arriving != nil { titled = true }
            else { withAnimation(HarborMotion.animation(level: level)) { titled = true } }
        }
        .onChange(of: session.phase) { _, next in if opening { phase = next } }
        .onChange(of: opening) { _, opening in opening ? begin() : finish() }
        .accessibilityIdentifier("workspace-opening")
    }

    /// The editor starts again (a reconnect): the title comes back down to say what is happening.
    private func begin() {
        covering = true; session.titleInFlight = travels
        withAnimation(HarborMotion.animation(HarborMotion.standard, level: level)) { landing = 0 }
    }
    private func finish() {
        guard covering else { return }
        // An error has a panel of its own under this page: step aside at once.
        guard session.ready || session.revealed, level != .off else { landing = 1; covering = false; session.titleInFlight = false; return }
        withAnimation(level == .full ? Self.flight : HarborMotion.animation(level: level), completionCriteria: .logicallyComplete) { landing = 1 } completion: {
            // Opening may have begun again while this ran.
            guard !opening else { return }
            covering = false; session.titleInFlight = false
        }
    }

    private var status: some View {
        VStack(spacing: 12) {
            Text(opening ? session.phase : phase).font(.system(size: 12)).foregroundStyle(WorkspaceTheme.muted).lineLimit(2).multilineTextAlignment(.center)
            if !session.starting && session.web == nil {
                Button("Open Editor") { session.start(store: store) }.buttonStyle(.borderedProminent)
            } else {
                // One line under the words, filling as the editor gets nearer.
                HarborProgressBar(pace: session.pace, width: 200).padding(.top, 2)
            }
            if let detail = session.detail {
                Text(detail).font(.system(size: 12).monospacedDigit()).foregroundStyle(WorkspaceTheme.muted)
                // Only while something is in fact being fetched or sent.
                Text("The editor is fetched once for each server. A slow or interrupted transfer continues where it stopped.")
                    .font(.system(size: 11)).foregroundStyle(WorkspaceTheme.muted).multilineTextAlignment(.center)
            }
            // Opened by mistake, or not worth the wait: stopping puts the window back where it was.
            Button("Stop") { store.stopOpening(workspace) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.harborAccent)
                .keyboardShortcut(.cancelAction).help("Stop opening this folder · Esc")
                .padding(.top, 4).opacity(opening ? 1 : 0).allowsHitTesting(opening)
                .accessibilityIdentifier("stop-opening")
        }
        .harborReveal(distance: 6, after: 0.08)
    }
}

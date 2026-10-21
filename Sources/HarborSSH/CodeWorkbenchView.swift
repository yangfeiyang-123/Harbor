import SwiftUI
import WebKit

struct CodeWorkbenchView: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var session: CodeWorkbenchSession
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    @AppStorage(HarborMotion.preferenceKey) private var motion = HarborMotion.Level.full.rawValue
    @AppStorage(WorkbenchPreferences.activityBarCountKey) private var activityCount = 4
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // The editor itself is on the window's stage, under this view, which stays through
                // every switch. What is said while an editor starts is the opening page's, over both.
                // Editor, terminal, dialogs and status bar share Code-OSS's
                // single layout and compositing tree. No native terminal overlay.
                if let error = session.error, !session.ready {
                    VStack(spacing: 10) {
                        Text("Editor connection").font(.system(size: 14, weight: .semibold))
                        Text(error).font(.system(size: 12)).textSelection(.enabled).lineLimit(8)
                        HStack(spacing: 10) {
                            Button("Reconnect Editor") { session.disconnect(); session.start(store: store) }
                            Button("Start Page") { store.page = .recent }
                        }
                    }.padding(20).frame(maxWidth: 500).background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspaceTheme.border, lineWidth: 1))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                // Beside an editor that is shown before Harbor's part of it is there; clicks go to the editor.
                if let notice = session.notice, session.error == nil {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                        Text(session.themeWaiting ? notice + " " + CodeWorkbenchSession.themeWaitingNote : notice)
                            .font(.system(size: 11)).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    }.padding(10).background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkspaceTheme.border, lineWidth: 1))
                        .frame(maxWidth: 420).padding(12)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
                }
                if let error = session.error, session.ready {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                        Text(error).font(.system(size: 11)).lineLimit(2)
                        Button("Reconnect") { session.disconnect(); session.start(store: store) }
                    }.padding(10).background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 440).padding(12)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
                }
            }.clipped().opacity(session.layoutOpacity)
        }
        // With nothing to say, clicks belong to the editor underneath.
        .allowsHitTesting(session.error != nil)
        .task { session.start(store: store) }
        // "System" modes must follow macOS as well as the stored selection.
        .task(id: appearance + (colorScheme == .dark ? ".dark" : ".light")) { await session.syncTheme() }
        .onChange(of: motion) { _, _ in session.syncMotion() }
        .onChange(of: activityCount) { _, _ in session.syncActivityBar() }
        .onChange(of: reduceMotion) { _, _ in session.syncMotion() }
        .onChange(of: workspace.enabled) { _, _ in Task { await session.updateTerminalPanel() } }
        .onChange(of: workspace.terminalVisible) { _, _ in Task { await session.updateTerminalPanel() } }
        .onChange(of: workspace.terminalMaximized) { _, _ in Task { await session.updateTerminalPanel() } }
        .onAppear { session.foreground = true }
        .onDisappear { session.foreground = false }
    }
}

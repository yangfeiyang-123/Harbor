import SwiftUI

/// The editor panel presents one session at a time. Selecting a row changes
/// focus only; the terminal mode's groups, split tree and proportions stay intact.
struct FileTerminalPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("fileTerminalListWidth") private var listWidth = 160.0
    @State private var dragStart: Double?
    @StateObject private var keyboard = TerminalListFocus()
    let scope: TerminalScope
    var body: some View {
        let arrangement = store.arrangement(in: scope)
        let selectedSession = store.selectedTerminal(in: scope)
        GeometryReader { geometry in
            let width = min(max(listWidth, 52), max(52, min(240, geometry.size.width * 0.35)))
            HStack(spacing: 0) {
                if let session = selectedSession {
                    SessionPanel(session: session, showsStatus: false).id(session.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                ResizeHandle(vertical: true, accessibilityReversed: true, label: "Resize Terminal List", reset: { listWidth = 160 }) { delta in
                    if dragStart == nil { dragStart = width }
                    // The list is on the right; dragging left makes it wider.
                    listWidth = min(max((dragStart ?? width) - delta, 52), max(52, min(240, geometry.size.width * 0.35)))
                } end: { dragStart = nil }
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 3) {
                            ForEach(arrangement.sessionIDs, id: \.self) { id in
                                if let session = store.sessions.first(where: { $0.id == id }) {
                                    FileTerminalRow(session: session, selected: id == arrangement.selectedID, width: width,
                                        select: { keyboard.view?.select(session) })
                                        .harborDropTarget(.list(id, scope), didDrop: { keyboard.view?.focusList() }).id(id)
                                }
                            }
                        }.padding(.vertical, 5).padding(.horizontal, 4)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: arrangement.sessionIDs)
                    }.onChange(of: arrangement.selectedID) { _, id in if let id { reader.scrollTo(id) } }
                        .onAppear { if let id = arrangement.selectedID { reader.scrollTo(id) } }
                }.frame(width: width).frame(maxHeight: .infinity)
                    .background(WorkspaceTheme.sidebar)
                    .background(TerminalListKeyboardBridge(store: store, scope: scope, focus: keyboard).accessibilityHidden(true))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { keyboard.view?.focusList() })
                    .accessibilityLabel("Terminal List")
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.clipped()
    }
}

struct FileTerminalRow: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: AppStore
    let selected: Bool
    let width: Double
    let select: () -> Void
    @State private var hovered = false
    private var reveal: Double { HarborLayout.reveal(width, from: 60, to: 135) }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6 * reveal) {
                    HarborSymbol(systemName: "terminal").font(.system(size: 13))
                        .foregroundStyle(selected ? Color.harborForeground : .harborMuted)
                        .frame(width: 22, height: 26)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(session.ended ? Color.harborMuted : session.ready ? .harborSuccess : .orange)
                                .frame(width: 4, height: 4).offset(x: 1, y: -1)
                        }
                    Text(session.tabTitle).harborFont(11).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading).opacity(reveal).clipped()
                }.padding(.leading, 7).frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(session.tabTitle)
                .accessibilityIdentifier("file-terminal-" + session.id.uuidString)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .simultaneousGesture(TapGesture(count: 2).onEnded { store.promptForTerminalName(session) })
                .compactHint(session.displayTitle, detail: session.workingDirectory ?? "", edge: .minX)
                .harborDragSource(.terminal(session.id, store.terminalScope(of: session)))
            Button { store.close(session) } label: {
                HarborSymbol(systemName: "xmark").font(.system(size: 9)).frame(width: 20, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Close " + session.tabTitle)
                .frame(width: 20 * reveal).opacity((hovered || selected) ? reveal : 0).clipped()
                .allowsHitTesting(reveal > 0.65 && (hovered || selected)).accessibilityHidden(reveal <= 0.65)
        }.frame(height: 30).clipped()
            .background(selected ? WorkspaceTheme.selection : hovered ? WorkspaceTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) { if selected { WorkspaceTheme.muted.frame(width: 2).padding(.vertical, 6) } }
            .onHover { hovered = $0 }
            .contextMenu {
                Button("Rename Terminal…") { store.promptForTerminalName(session) }
                Button("Close Terminal") { store.close(session) }
            }
    }
}

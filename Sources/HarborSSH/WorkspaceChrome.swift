import SwiftUI
import AppKit

enum WorkspaceTabLayout {
    static let minimum = 40.0
    static let maximum = 360.0
    static func clamp(_ width: Double) -> Double { min(max(width.isFinite ? width : 150, minimum), maximum) }
    static func fittedWidth(_ title: String) -> Double {
        clamp(Double((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 66)
    }
    // Resolve collisions within the open group, so even paths with the same hash
    // receive distinct colors. Sorting makes the assignment independent of tab order.
    static func colorIndex(path: String, peers: [String]) -> Int? {
        let name = (path as NSString).lastPathComponent
        let group = Set(peers.filter { ($0 as NSString).lastPathComponent == name }).sorted()
        guard group.count > 1 else { return nil }
        var used = Set<Int>()
        for item in group {
            let hash = item.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            var slot = Int(hash % 12)
            while used.contains(slot) && used.count < 12 { slot = (slot + 1) % 12 }
            used.insert(slot)
            if item == path { return slot }
        }
        return nil
    }
    static func disambiguatedTitle(path: String, peers: [String]) -> String {
        let name = (path as NSString).lastPathComponent
        let group = peers.filter { $0 != path && ($0 as NSString).lastPathComponent == name }
        guard !group.isEmpty else { return name }
        let parts = path.split(separator: "/").map(String.init)
        for count in 2...max(2, parts.count) {
            let suffix = parts.suffix(count).joined(separator: "/")
            if !group.contains(where: { $0.split(separator: "/").suffix(count).joined(separator: "/") == suffix }) { return suffix }
        }
        return path
    }
}

/// A tab's own trailing edge adjusts its width, independently of every pane.
struct WorkspaceTab: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    var tint: Color = .harborIcon
    var status: Color?
    var dirty = false
    @Binding var width: Double
    let select: () -> Void
    let close: () -> Void
    var rename: (() -> Void)?
    var renameLabel = "Rename Terminal…"
    var dragSource: HarborDragSource?
    var flat = false
    var revealFile: (() -> Void)?
    var closeOthers: (() -> Void)?
    var copyPath: (() -> Void)?
    var filePath: String?
    var fileLabelTint: Color?
    @State private var dragStart: Double?
    @State private var hovered = false
    private var actualWidth: Double { WorkspaceTabLayout.clamp(width) }
    private var reveal: Double { HarborLayout.reveal(actualWidth, from: 48, to: 115) }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 7 * reveal) {
                    Group {
                        if let filePath { WorkspaceFileIcon(path: filePath) }
                        else { HarborSymbol(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint) }
                    }.frame(width: 22, height: 26).overlay(alignment: .bottomTrailing) {
                            if (dirty && !flat) || status != nil { Circle().fill(dirty ? .orange : status!).frame(width: 5, height: 5).offset(x: 1, y: -1) }
                        }
                    Text(title).harborFont(12).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(fileLabelTint ?? (flat ? (selected ? WorkspaceTheme.foreground : WorkspaceTheme.muted) : (selected ? Color.harborForeground : .harborMuted)))
                        .frame(maxWidth: .infinity, alignment: .leading).opacity(reveal).clipped()
                }.padding(.leading, 8).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
                .simultaneousGesture(TapGesture(count: 2).onEnded { rename?() })
                .compactHint(title, detail: detail, edge: .minY)
                .harborDragSource(dragSource)
            Button(action: close) {
                HarborSymbol(systemName: dirty ? "circle.fill" : "xmark").font(.system(size: dirty ? 6 : 9))
                    .frame(width: 22, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Close " + title)
                .frame(width: 22 * reveal).opacity(reveal).clipped().allowsHitTesting(reveal > 0.45).accessibilityHidden(reveal <= 0.45)
            Color.clear.frame(width: 7)
        }.frame(width: actualWidth, height: flat ? 35 : 32).clipped()
            .foregroundStyle(flat ? (selected ? WorkspaceTheme.foreground : WorkspaceTheme.muted) : (selected ? Color.harborForeground : .harborMuted))
            .background {
                if flat { (selected ? WorkspaceTheme.background : hovered ? WorkspaceTheme.hover : WorkspaceTheme.sidebar) }
                else { Color.clear.harborSelectionGlass(selected, radius: 6, inactive: .harborTabInactive, active: .harborTabActive) }
            }
            .overlay(alignment: .bottom) { if selected && !flat { Color.harborTabBorder.frame(height: 2).padding(.horizontal, 5) } }
            .overlay(alignment: .trailing) {
                Rectangle().fill(hovered || dragStart != nil ? tint.opacity(0.45) : Color.harborBorder)
                    .frame(width: 1, height: 15).frame(width: 7, height: 32).contentShape(Rectangle())
                    .onHover { ($0 ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged {
                        if dragStart == nil { dragStart = actualWidth }
                        width = WorkspaceTabLayout.clamp((dragStart ?? actualWidth) + $0.translation.width)
                    }.onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { width = WorkspaceTabLayout.fittedWidth(title) }
                    .help("Drag to resize the tab; double-click to fit its name")
                    .accessibilityLabel("Resize \(title) tab")
                    .accessibilityAdjustableAction { width = WorkspaceTabLayout.clamp(actualWidth + ($0 == .increment ? 20 : -20)) }
            }
            .onHover { hovered = $0 }
            .contextMenu {
                if let rename { Button(renameLabel, action: rename) }
                Button("Icons Only") { width = WorkspaceTabLayout.minimum }
                Button("Fit Tab to Name") { width = WorkspaceTabLayout.fittedWidth(title) }
                if let revealFile { Button("Reveal in Explorer", action: revealFile) }
                if let copyPath { Button("Copy Path", action: copyPath) }
                Divider().overlay(Color.harborBorder)
                Button("Close", action: close)
                if let closeOthers { Button("Close Others", action: closeOthers) }
            }
    }
}

struct EditorPosition: Equatable {
    var line = 1
    var column = 1
    var lines = 1
    var label: String { "Ln \(line), Col \(column) · \(lines) lines · UTF-8" }
}

struct WorkspaceStatusBar: View {
    @ObservedObject var workspace: FileWorkspace
    let session: TerminalSession?
    var body: some View {
        HStack(spacing: 12) {
            if let session { ConnectionStatus(session: session) }
            else { Label(workspace.profile == nil ? "Local" : "SSH · \(workspace.profile!.name)", systemImage: workspace.profile?.displayIcon ?? "laptopcomputer") }
            Spacer(minLength: 8)
            FileTransferIndicator(workspace: workspace)
            if workspace.enabled, let document = workspace.currentDocument { DocumentStatus(document: document) }
        }.harborFont(10).foregroundStyle(workspace.enabled ? WorkspaceTheme.muted : Color.harborMuted).padding(.horizontal, 12).frame(height: workspace.enabled ? 24 : 26)
            .frame(maxWidth: .infinity).background(workspace.enabled ? WorkspaceTheme.sidebar : Color.harborBackground)
    }
}
struct ConnectionStatus: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(session.ready ? Color.harborSuccess : .secondary).frame(width: 5, height: 5)
            Text(session.status).lineLimit(1)
            if session.tmuxName != nil { Image(systemName: "arrow.clockwise").help("Restorable tmux session") }
        }
    }
}
struct DocumentStatus: View {
    @ObservedObject var document: WorkspaceDocument
    var body: some View {
        HStack(spacing: 8) {
            if document.dirty { Text("Unsaved").foregroundStyle(.orange) }
            if document.text != nil { Text(document.position.label).monospacedDigit() }
            else { Text(document.entry.name).lineLimit(1).truncationMode(.middle) }
        }.lineLimit(1)
    }
}

struct WorkspaceSplitLayout {
    let editor: Double
    let terminal: Double
    static let divider = 7.0
    init(height: Double, ratio: Double, terminalMinimum requestedMinimum: Double = 90) {
        let available = max(0, height - Self.divider)
        let terminalMinimum = min(max(0, requestedMinimum), available)
        editor = min(max(available * (ratio.isFinite ? ratio : 0.64), 0), available - terminalMinimum)
        terminal = available - editor
    }
}

/// Present native child bounds at each animation frame, including zero height.
struct InterpolatedHeight<Content: View>: View, Animatable {
    var height: Double
    @ViewBuilder var content: (Double) -> Content
    var animatableData: Double { get { height } set { height = newValue } }
    var body: some View { content(max(0, height)).transaction { $0.animation = nil } }
}

/// AppKit children must never negotiate a document-sized SwiftUI frame or paint
/// outside their pane. In particular WKWebView and PDFView retain large sizes.
final class BoundedNativeView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        content.removeFromSuperview(); content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.init(1), for: .horizontal)
        content.setContentHuggingPriority(.init(1), for: .vertical)
        content.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        content.setContentCompressionResistancePriority(.init(1), for: .vertical)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

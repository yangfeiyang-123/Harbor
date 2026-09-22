import SwiftUI
import HarborCore

struct WorkspaceFileTab: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var document: WorkspaceDocument
    @AppStorage("fileTabWidth") private var defaultWidth = 165.0
    @Environment(\.colorScheme) private var colorScheme
    private var paths: [String] { workspace.documents.map { $0.entry.path } }
    private var duplicateTint: Color? {
        guard let slot = WorkspaceTabLayout.colorIndex(path: document.entry.path, peers: paths) else { return nil }
        return Color(hue: Double(slot) / 12, saturation: colorScheme == .dark ? 0.48 : 0.68, brightness: colorScheme == .dark ? 0.92 : 0.64)
    }
    var body: some View {
        WorkspaceTab(title: WorkspaceTabLayout.disambiguatedTitle(path: document.entry.path, peers: paths),
                     detail: (document.dirty ? "Unsaved · " : "") + document.entry.path,
                     symbol: "doc", selected: workspace.selection == document.id, tint: duplicateTint ?? WorkspaceTheme.muted, dirty: document.dirty,
                     width: Binding(get: { document.tabWidth ?? defaultWidth }, set: { document.tabWidth = $0; defaultWidth = $0 }),
                     select: { workspace.selection = document.id; workspace.requestFocus(.editor) },
                     close: { workspace.close(document) }, flat: true,
                     revealFile: { Task { await workspace.revealInExplorer(document.entry.path) } },
                     closeOthers: { workspace.closeOtherDocuments(keeping: document) },
                     copyPath: { store.copyEntryPath(document.entry) },
                     filePath: document.entry.path, fileLabelTint: duplicateTint)
            .onAppear { if document.tabWidth == nil { document.tabWidth = WorkspaceTabLayout.clamp(defaultWidth) } }
    }
}

struct DocumentActions: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var document: WorkspaceDocument
    var body: some View {
        HStack(spacing: 2) {
            if document.kind == .markdown {
                Button { document.preview.toggle() } label: {
                    HarborSymbol(systemName: document.preview ? "chevron.left.forwardslash.chevron.right" : "doc.richtext").frame(width: 26, height: 28)
                }.accessibilityLabel(document.preview ? "Markdown Source" : "Markdown Preview").help(document.preview ? "Show Markdown Source" : "Preview Markdown")
            }
            if document.kind == .pdf {
                Menu {
                    Button("Zoom In PDF") { document.pdfView?.zoomIn(nil) }
                    Button("Zoom Out PDF") { document.pdfView?.zoomOut(nil) }
                    Button("Fit to Window") { document.pdfView?.autoScales = true }
                } label: { HarborSymbol(systemName: "plus.magnifyingglass").frame(width: 26, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("PDF Zoom")
            }
            if document.text != nil && (document.dirty || document.saving) {
                Button { Task { await workspace.save(document) } } label: {
                    HarborSymbol(systemName: document.saving ? "hourglass" : "square.and.arrow.down").frame(width: 26, height: 28)
                }.disabled(!document.dirty || document.saving).accessibilityLabel("Save File").help("Save File ⌘S")
            }
        }
    }
}

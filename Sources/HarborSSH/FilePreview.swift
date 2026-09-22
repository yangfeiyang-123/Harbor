import SwiftUI
import WebKit
import PDFKit
import AVKit
import ImageIO
import HarborCore

struct FilePreview: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var document: WorkspaceDocument
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            if let error = document.error {
                HStack(alignment: .top) { HarborSymbol(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled); Spacer(); Button("Dismiss") { document.error = nil } }
                    .harborFont(11).foregroundStyle(.orange).padding(12).background(Color.orange.opacity(0.06))
            }
            if document.loading { ProgressView("Loading \(document.entry.name)…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if document.text != nil { CodeEditor(document: document, workspace: workspace) }
            else if let url = document.localURL {
                switch document.kind {
                case .pdf: PDFPreview(url: url, document: document)
                case .video, .audio: MediaPreview(url: url).id(url)
                case .image: ImagePreview(url: url)
                default: Text("Preview Unavailable for This Format").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label(document.entry.name, systemImage: "doc")
                } description: {
                    Text(ByteCountFormatter.string(fromByteCount: document.entry.size, countStyle: .file))
                } actions: {
                    Button("Load Preview") { Task { await workspace.load(document) } }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .onAppear { workspace.showPreview(document) }
            .onDisappear { workspace.hidePreview(document) }
            .task(id: document.id) { await workspace.loadIfNeeded(document) }
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL
    let document: WorkspaceDocument
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> BoundedNativeView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = PDFDocument(url: url)
        document.pdfView = view; return BoundedNativeView(content: view)
    }
    func updateNSView(_ view: BoundedNativeView, context: Context) {
        if document.pdfView?.document?.documentURL != url { document.pdfView?.document = PDFDocument(url: url) }
        document.pdfView?.backgroundColor = WorkspaceTheme.native("editor.background", dark: colorScheme == .dark)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundedNativeView, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
}
struct ImagePreview: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(20) }
            else { ContentUnavailableView("Unable to Decode Image", systemImage: "photo") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).task(id: url) {
            let loaded = await Task.detached(priority: .utility) { PreviewImageLoader.load(url) }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}
enum PreviewImageLoader {
    /// Fit large still images to a Retina display without decoding an entire
    /// research image into RAM. The original file remains untouched.
    static func load(_ url: URL, maximumPixelSize: Int = 4096) -> NSImage? {
        guard url.pathExtension.lowercased() != "gif",
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maximumPixelSize else { return NSImage(contentsOf: url) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
struct MediaPreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var unsupported = false
    var body: some View {
        Group {
            if unsupported { ContentUnavailableView("Unsupported Media Codec", systemImage: "play.slash", description: Text("Convert the file to MP4 with H.264 / AAC to preview it.")) }
            else { NativeMediaPlayer(player: player) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: url) {
                let asset = AVURLAsset(url: url)
                unsupported = (try? await asset.load(.isPlayable)) != true
                if !unsupported && !Task.isCancelled {
                    player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                }
            }.onDisappear { player?.pause(); player = nil }
    }
}
struct NativeMediaPlayer: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.showsFullScreenToggleButton = true; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

@MainActor final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    let web: WKWebView
    weak var document: WorkspaceDocument?
    weak var workspace: FileWorkspace?
    var ready = false
    private var focusPending = false
    var options: [String: Any] = [:]
    var signature = ""
    init(document: WorkspaceDocument, workspace: FileWorkspace) {
        self.document = document; self.workspace = workspace
        let config = WKWebViewConfiguration(); config.websiteDataStore = Self.dataStore
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakEditorHandler(self), name: "harbor")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        let root = AppResources.directory("Editor")
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }
    func update(dark: Bool, font: Double, wrap: Bool) {
        guard let document else { return }
        let next = "\(dark)-\(font)-\(wrap)-\(document.preview)-\(document.revision)"
        guard next != signature else { return }; signature = next
        options = ["text": document.text ?? "", "path": document.entry.path, "revision": document.revision,
                   "preview": document.kind == .markdown && document.preview, "font": font, "dark": dark, "wrap": wrap]
        if let snapshot = document.editorSnapshot { options["snapshot"] = snapshot }
        push()
    }
    func push() {
        guard ready, !options.isEmpty else { return }
        let values = options
        Task {
            do {
                _ = try await web.callAsyncJavaScript("window.harborSet(options)", arguments: ["options": values], in: nil, contentWorld: .page)
                if let position = document?.pendingPosition {
                    document?.pendingPosition = nil
                    _ = try await web.callAsyncJavaScript("window.harborReveal(line, column)", arguments: ["line": position.line, "column": position.column], in: nil, contentWorld: .page)
                }
                if focusPending, workspace?.enabled == true, workspace?.terminalMaximized == false,
                   workspace?.focusArea == .editor, workspace?.currentDocument?.id == document?.id {
                    focusPending = false
                    web.window?.makeFirstResponder(web)
                    _ = try await web.evaluateJavaScript("window.harborFocus()")
                }
            }
            catch { document?.error = "Unable to load editor: " + error.localizedDescription }
        }
    }
    func focus() {
        focusPending = true
        push()
    }
    func cancelPendingFocus() { focusPending = false }
    func suspend() async -> Bool {
        cancelPendingFocus()
        guard let document, let workspace, workspace.visibleDocumentID != document.id else { return false }
        let revision = document.revision
        do {
            let snapshot = try await web.evaluateJavaScript("window.harborSnapshot?.()") as? [String: Any]
            guard workspace.visibleDocumentID != document.id, document.editor === self, revision == document.revision else { return false }
            if let state = snapshot?["state"] as? [String: Any], let text = state["doc"] as? String {
                document.text = text; document.editorSnapshot = snapshot
            } else if ready { return false }
            web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "harbor")
            document.editor = nil
            return true
        } catch { return false }
    }
    func find() { document?.preview = false; web.evaluateJavaScript("window.harborFind()") }
    func reveal(line: Int, column: Int = 1) {
        document?.preview = false; document?.pendingPosition = (line, column)
        workspace?.requestFocus(.editor); push()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready": ready = true; push()
        case "position":
            if let line = body["line"] as? Int, let column = body["column"] as? Int, let lines = body["lines"] as? Int {
                let position = EditorPosition(line: max(1, line), column: max(1, column), lines: max(1, lines))
                if document?.position != position { document?.position = position }
            }
        case "change": if let text = body["text"] as? String { document?.text = text }
        case "save": if let document, let workspace { Task { await workspace.save(document) } }
        case "link":
            if let value = body["url"] as? String, let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(navigationAction.navigationType == .other && url?.lastPathComponent == "index.html" && url?.isFileURL == true ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; signature = ""; document?.error = "The editor reloaded. Your unsaved content is still available."; webView.reload()
    }
}
private final class WeakEditorHandler: NSObject, WKScriptMessageHandler {
    weak var target: EditorBridge?
    init(_ target: EditorBridge) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}
struct CodeEditor: NSViewRepresentable {
    @ObservedObject var document: WorkspaceDocument
    let workspace: FileWorkspace
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorFontSize") private var font = 13.0
    @AppStorage("editorWrap") private var wrap = false
    func makeNSView(context: Context) -> BoundedNativeView {
        if document.editor == nil { document.editor = EditorBridge(document: document, workspace: workspace) }
        return BoundedNativeView(content: document.editor!.web)
    }
    func updateNSView(_ view: BoundedNativeView, context: Context) { document.editor?.update(dark: colorScheme == .dark, font: min(max(font, 9), 32), wrap: wrap) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundedNativeView, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
}

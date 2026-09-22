import XCTest
import AppKit
import SwiftUI
import Darwin
import WebKit
import ImageIO
import UniformTypeIdentifiers
import HarborCore
@testable import HarborSSH

final class ResourceBudgetTests: XCTestCase {
    @MainActor private func waitForEditor(_ document: WorkspaceDocument, window: NSWindow) async throws -> EditorBridge {
        let deadline = Date().addingTimeInterval(8)
        while document.editor?.ready != true && Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(document.editor?.ready == true)
        let bridge = try XCTUnwrap(document.editor)
        _ = try await bridge.web.callAsyncJavaScript("await Promise.race([new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))), new Promise(resolve => setTimeout(resolve, 1600))]); return true;", arguments: [:], in: nil, contentWorld: .page)
        return bridge
    }
    @MainActor func testSuspendedEditorRestoresUnsavedTextUndoSelectionAndScroll() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-editor-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.editor-state." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        defer { store.shutdown() }
        store.loading = false; store.selectWorkspace(nil)
        let workspace = store.currentFiles; workspace.root = root.path; workspace.enabled = true; workspace.entries[root.path] = []
        let document = WorkspaceDocument(.init(path: root.appendingPathComponent("draft.py").path, name: "draft.py", directory: false, size: 1000, modified: 0))
        let original = String(repeating: "print('keep CRLF')\r\n", count: 150)
        document.text = original; document.savedText = original
        workspace.documents = [document]; workspace.selection = document.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var bridge: EditorBridge? = try await waitForEditor(document, window: window)
        _ = try await bridge!.web.evaluateJavaScript("window.harborFocus(); document.execCommand('insertText', false, '# unsaved edit');")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(document.dirty); XCTAssertTrue(document.text?.contains("# unsaved edit") == true)
        _ = try await bridge!.web.callAsyncJavaScript("await Promise.race([new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))), new Promise(resolve => setTimeout(resolve, 1600))]); return true;", arguments: [:], in: nil, contentWorld: .page)
        _ = try await bridge!.web.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop = 500;")
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeValue = try await bridge!.web.evaluateJavaScript("window.harborSnapshot()")
        let before = try XCTUnwrap(beforeValue as? [String: Any])
        workspace.enabled = false
        try await Task.sleep(nanoseconds: 300_000_000); await workspace.trimEditors()
        XCTAssertNil(document.editor)
        XCTAssertNotNil(document.editorSnapshot)
        bridge = nil
        workspace.enabled = true
        let restored = try await waitForEditor(document, window: window)
        let afterValue = try await restored.web.evaluateJavaScript("window.harborSnapshot()")
        let after = try XCTUnwrap(afterValue as? [String: Any])
        let oldState = try XCTUnwrap(before["state"] as? NSDictionary), newState = try XCTUnwrap(after["state"] as? NSDictionary)
        XCTAssertEqual(oldState, newState, "Text, CRLF, selection and undo state must survive releasing WKWebView")
        let cachedTop = document.editorSnapshot?["top"] as? Double ?? 0
        XCTAssertEqual(after["top"] as? Double ?? 0, before["top"] as? Double ?? 0, accuracy: 1, "cached=\(cachedTop), web frame=\(restored.web.bounds)")
        _ = try await restored.web.evaluateJavaScript("window.harborFocus(); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'z', code:'KeyZ', metaKey:true, bubbles:true}));")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(document.text, original, "Undo must still work after the editor is re-created")
    }
    func testLargeImagePreviewIsBoundedWithoutChangingOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-image-budget-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 8192, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8192, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: root)
        let image = try XCTUnwrap(PreviewImageLoader.load(root, maximumPixelSize: 1024))
        let decoded = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(decoded.width, 1024); XCTAssertEqual(decoded.height, 4)
        XCTAssertEqual(try Data(contentsOf: root), before)
    }
    @MainActor func testEditorWorkingSetAndMemorySample() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-resource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.resources." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        defer { store.shutdown() }
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        let workspace = store.currentFiles; workspace.root = root.path; workspace.enabled = true
        await workspace.prepare(store: store)
        var paths: [String] = []
        for i in 0..<12 {
            let file = root.appendingPathComponent("sample-\(i).py")
            try ("# File \(i)\n" + String(repeating: "print('resource benchmark with a normal source file')\n", count: 1500)).write(to: file, atomically: true, encoding: .utf8)
            paths.append(file.path)
        }
        await workspace.navigate(root.path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        for path in paths {
            let entry = try XCTUnwrap(workspace.entries[workspace.root]?.first { $0.name == (path as NSString).lastPathComponent }, "root=\(workspace.root), error=\(String(describing: workspace.error))")
            await workspace.open(entry)
            let deadline = Date().addingTimeInterval(8)
            while workspace.currentDocument?.editor?.ready != true && Date() < deadline {
                window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertTrue(workspace.currentDocument?.editor?.ready == true)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        let retained = workspace.documents.filter { $0.editor != nil }.count
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let baseline = ProcessInfo.processInfo.environment["HARBOR_MEMORY_BASELINE"] == "1"
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"] {
            let result: [String: Any] = ["mode": baseline ? "before" : "after", "open_files": workspace.documents.count,
                "retained_editors": retained, "main_process_phys_footprint_bytes": status == KERN_SUCCESS ? info.phys_footprint : 0,
                "scope": "isolated native test process, excludes WebKit helper processes", "file_bytes_each": try Data(contentsOf: URL(fileURLWithPath: paths[0])).count]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent(baseline ? "memory-before.json" : "memory-after.json"))
        }
        if !baseline { XCTAssertLessThanOrEqual(retained, 3) }
        XCTAssertEqual(workspace.documents.count, 12)
    }
}

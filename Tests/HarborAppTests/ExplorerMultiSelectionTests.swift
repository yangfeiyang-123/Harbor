import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class ExplorerMultiSelectionTests: XCTestCase {
    @MainActor private func fixture() async throws -> (AppStore, FileWorkspace, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-multi-" + UUID().uuidString).resolvingSymlinksInPath()
        let work = root.appendingPathComponent("WorkSpace")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let suite = "app.harbor.multi." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.py", "beta.py", "gamma.py"] {
            try name.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let folder = work.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "child".write(to: folder.appendingPathComponent("child.py"), atomically: true, encoding: .utf8)
        let store = AppStore(historyRoot: root.appendingPathComponent("app-data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        let files = store.currentFiles; files.enabled = true
        await files.prepare(store: store); await files.navigate(work.path)
        return (store, files, root)
    }
    @MainActor private func entry(_ name: String, in files: FileWorkspace) throws -> WorkspaceEntry {
        try XCTUnwrap(files.visibleRows.first { $0.entry.name == name }?.entry)
    }

    @MainActor func testModifierClicksUseVisibleTreeOrderWithoutOpeningOrExpanding() async throws {
        let (store, files, _) = try await fixture(); defer { store.shutdown() }
        let a = try entry("alpha.py", in: files), b = try entry("beta.py", in: files), c = try entry("gamma.py", in: files)
        let folder = try entry("folder", in: files)
        XCTAssertTrue(files.selectExplorerEntry(a, modifiers: []))
        XCTAssertFalse(files.selectExplorerEntry(c, modifiers: .command))
        XCTAssertEqual(files.selectedEntries.map(\.name), ["alpha.py", "gamma.py"])
        XCTAssertFalse(files.selectExplorerEntry(a, modifiers: .command))
        XCTAssertEqual(files.selectedEntries.map(\.name), ["gamma.py"])
        XCTAssertFalse(files.selectExplorerEntry(b, modifiers: .shift))
        XCTAssertEqual(files.selectedEntries.map(\.name), ["alpha.py", "beta.py"])
        XCTAssertFalse(files.selectExplorerEntry(folder, modifiers: .command))
        XCTAssertFalse(files.expanded.contains(folder.path)); XCTAssertTrue(files.documents.isEmpty)
        files.selectExplorerEntry(c, modifiers: [])
        XCTAssertEqual(files.selectedEntries.map(\.name), ["gamma.py"])

        await files.toggle(folder)
        let child = try entry("child.py", in: files)
        files.selectExplorerEntry(folder, modifiers: [])
        files.selectExplorerEntry(a, modifiers: .shift)
        XCTAssertEqual(files.selectedEntries.map(\.name), ["folder", "child.py", "alpha.py"])
        await files.toggle(folder)
        XCTAssertFalse(files.explorerSelection.paths.contains(child.path))
        files.query = "alpha"
        XCTAssertEqual(files.selectedEntries.map(\.name), ["alpha.py"])
        try FileManager.default.removeItem(atPath: a.path)
        await files.refreshExpanded(force: true)
        XCTAssertTrue(files.selectedEntries.isEmpty)
    }

    @MainActor func testMultiCopyAndDragRetainEveryPathAndSourceServer() async throws {
        let (store, files, _) = try await fixture(); defer { store.shutdown() }
        let a = try entry("alpha.py", in: files), b = try entry("beta.py", in: files), c = try entry("gamma.py", in: files)
        files.selectExplorerEntry(a, modifiers: []); files.selectExplorerEntry(c, modifiers: .command)
        let clipboard = NSPasteboard(name: .init(UUID().uuidString)); defer { clipboard.releaseGlobally() }
        store.copyEntries(files.selectedEntries, in: files, clipboard: clipboard)
        XCTAssertEqual(try store.clipboardEntries(clipboard).map { $0.entry.path }, [a.path, c.path])
        let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.path), [a.path, c.path])
        XCTAssertEqual(clipboard.string(forType: .string), [a.path, c.path].joined(separator: "\n"))
        let selected = files.entriesForDrag(from: a)
        XCTAssertEqual(selected.map(\.path), [a.path, c.path])
        let remoteID = UUID(), provider = WorkspaceDragDrop.provider(for: selected, profileID: remoteID)
        let items = try await WorkspaceDragDrop.items(from: [provider])
        XCTAssertEqual(items.map { $0.entry.path }, [a.path, c.path])
        XCTAssertTrue(items.allSatisfy { $0.profileID == remoteID })
        XCTAssertEqual(try WorkspaceDragDrop.terminalText(items, profileID: remoteID), [a.path, c.path].map(SSHArguments.quote).joined(separator: " ") + " ")
        XCTAssertEqual(files.entriesForAction(on: a).count, 2)
        XCTAssertEqual(files.entriesForAction(on: b), [b])
        XCTAssertEqual(files.entriesForDrag(from: b), [b])
        store.copyEntryPaths([a, c], clipboard: clipboard)
        XCTAssertNil(clipboard.data(forType: .init(WorkspaceDropItem.typeIdentifier)))
        XCTAssertEqual(clipboard.string(forType: .string), a.path + "\n" + c.path)
    }

    @MainActor func testBatchMoveCopyAndDownloadKeepDraftsAndAllDestinations() async throws {
        let (store, files, root) = try await fixture(); defer { store.shutdown() }
        let a = try entry("alpha.py", in: files), b = try entry("beta.py", in: files), folder = try entry("folder", in: files)
        await files.open(a); let document = try XCTUnwrap(files.currentDocument); document.text = "unsaved draft"
        await store.transferEntries([a, b].map { WorkspaceDropItem(profileID: nil, entry: $0) }, to: folder.path, in: files, move: true)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(files.selectedEntries.map(\.name), ["alpha.py", "beta.py"])
        XCTAssertTrue(files.selectedEntries.allSatisfy { $0.path.hasPrefix(folder.path + "/") })
        XCTAssertEqual(document.entry.path, folder.path + "/alpha.py")
        XCTAssertEqual(document.text, "unsaved draft"); XCTAssertTrue(document.dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        let moved = files.selectedEntries
        await store.transferEntries(moved.map { WorkspaceDropItem(profileID: nil, entry: $0) }, to: files.root, in: files, move: false)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(Set(files.selectedEntries.map(\.path)), [a.path, b.path])
        XCTAssertEqual(try String(contentsOfFile: a.path, encoding: .utf8), "alpha.py")

        let download = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: false)
        // Selecting a folder and one of its children must export the child once.
        let urls = try await store.downloadEntries([folder, moved[0], try entry("gamma.py", in: files)], to: download, in: files)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["folder", "gamma.py"])
        XCTAssertEqual(try String(contentsOf: download.appendingPathComponent("folder/beta.py"), encoding: .utf8), "beta.py")
        XCTAssertEqual(try String(contentsOf: download.appendingPathComponent("gamma.py"), encoding: .utf8), "gamma.py")
        XCTAssertFalse(files.fileOperation)
    }

    @MainActor func testBatchDeleteChecksAllUnsavedFilesBeforeDeletingAnything() async throws {
        let (store, files, _) = try await fixture(); defer { store.shutdown() }
        let a = try entry("alpha.py", in: files), b = try entry("beta.py", in: files)
        await files.open(b); files.currentDocument?.text = "draft"
        await store.trashEntries([a, b], in: files)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(store.errorMessage?.contains("unsaved changes") == true)
        XCTAssertFalse(files.fileOperation)
    }

    @MainActor func testKeyboardSelectionAndReturnStayScopedToExplorer() async throws {
        let (store, files, _) = try await fixture(); defer { store.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
        let list = BrowserListKeyView(); list.store = store; list.workspace = files
        let input = NSTextView(); window.contentView = NSView()
        window.contentView!.addSubview(list); window.contentView!.addSubview(input)
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        list.focusList()
        files.selectExplorerEntry(try entry("alpha.py", in: files), modifiers: [])
        XCTAssertTrue(store.handleExplorerKey(event(125, .shift)))
        XCTAssertEqual(files.selectedEntries.map(\.name), ["alpha.py", "beta.py"])
        XCTAssertTrue(store.handleExplorerKey(event(36))) // Multiple items never open a single-item rename dialog.
        XCTAssertFalse(store.handleExplorerKey(event(36, .command)))
        XCTAssertFalse(store.handleExplorerKey(event(36, .shift)))
        XCTAssertTrue(store.handleExplorerKey(event(0, .command)))
        XCTAssertEqual(files.selectedEntries.count, files.visibleRows.count)
        window.makeFirstResponder(input)
        XCTAssertFalse(store.handleExplorerKey(event(0, .command)))
        XCTAssertFalse(store.handleExplorerKey(event(125, .shift)))
        XCTAssertFalse(store.handleExplorerKey(event(51, .command)))
        list.focusList(); XCTAssertTrue(store.handleExplorerKey(event(53)))
        XCTAssertTrue(files.selectedEntries.isEmpty)
    }

    @MainActor func testBlankExplorerClickAndContextMenuClearChildSelectionWithoutChangingDrafts() async throws {
        let (store, files, _) = try await fixture(); defer { store.shutdown() }
        let folder = try entry("folder", in: files), file = try entry("alpha.py", in: files)
        await files.open(file)
        let draft = try XCTUnwrap(files.currentDocument); draft.text = "keep this draft"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
        let list = BrowserListKeyView(); list.store = store; list.workspace = files
        let focus = BrowserListFocus(); focus.view = list
        let background = ExplorerBackgroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        background.store = store; background.workspace = files; background.focus = focus
        window.contentView = NSView(); window.contentView!.addSubview(background); window.contentView!.addSubview(list)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        files.selectExplorerEntry(folder, modifiers: [])
        files.selectExplorerEntry(file, modifiers: .command)
        background.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertTrue(files.explorerRootSelected)
        XCTAssertNil(files.explorerSelection.anchorPath)
        XCTAssertNil(files.selectedEntry)
        XCTAssertTrue(window.firstResponder === list)

        // A right-click must also reset the destination without requiring a left-click first.
        files.selectExplorerEntry(folder, modifiers: [])
        let menu = try XCTUnwrap(background.menu(for: mouse(.rightMouseDown)))
        XCTAssertTrue(files.explorerRootSelected)
        XCTAssertTrue(files.selectedEntries.isEmpty)
        XCTAssertEqual(menu.items.prefix(2).map(\.title), ["New File…", "New Folder…"])
        XCTAssertTrue(menu.items.prefix(2).allSatisfy(\.isEnabled))
        XCTAssertTrue(files.currentDocument === draft)
        XCTAssertEqual(draft.text, "keep this draft"); XCTAssertTrue(draft.dirty)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!
        XCTAssertTrue(store.handleExplorerKey(delete))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path + "/child.py"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Ordinary row selection still exits root selection and uses the row.
        files.selectExplorerEntry(folder, modifiers: [])
        XCTAssertFalse(files.explorerRootSelected)
        XCTAssertEqual(files.selectedEntry?.path, folder.path)
    }
}

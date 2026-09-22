import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class ExplorerWorkflowTests: XCTestCase {
    @MainActor func fixture() throws -> (AppStore, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-explorer-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "app.harbor.explorer." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("app-data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        return (store, root)
    }
    @MainActor func testMoveAndRenameUpdateOpenDraftAndFileDropKeepsWorkspaceRoot() async throws {
        let (store, root) = try fixture(); defer { store.shutdown() }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try "initial".write(to: source.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        let files = store.currentFiles; files.enabled = true
        await files.prepare(store: store); await files.navigate(root.path)
        let folder = try XCTUnwrap(files.entries[files.root]?.first { $0.path == source.path })
        await files.toggle(folder)
        let entry = try XCTUnwrap(files.entries[source.path]?.first)
        await files.open(entry); let document = try XCTUnwrap(files.currentDocument); document.text = "unsaved change"
        files.entries[target.appendingPathComponent("source").path] = [] // A removed external folder can leave a stale cache key.
        await store.transferEntries([WorkspaceDropItem(profileID: nil, entry: folder)], to: target.path, in: files, move: true)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(document.entry.path, target.appendingPathComponent("source/main.py").path)
        XCTAssertTrue(document.dirty); XCTAssertEqual(document.text, "unsaved change")
        await store.mutateEntry(document.entry, in: files, operation: "rename", name: "updated.py")
        XCTAssertEqual(document.entry.name, "updated.py"); XCTAssertTrue(document.dirty)
        await files.save(document); XCTAssertFalse(document.dirty)
        XCTAssertEqual(try String(contentsOfFile: document.entry.path, encoding: .utf8), "unsaved change")
        let loose = root.appendingPathComponent("loose.txt"); try "loose".write(to: loose, atomically: true, encoding: .utf8)
        let plan = try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: [loose]))
        await store.openDroppedWorkspace(plan, target: files)
        XCTAssertTrue(store.currentFiles === files); XCTAssertEqual(files.root, root.path)
        XCTAssertEqual(files.documents.count, 2); XCTAssertEqual(files.currentDocument?.text, "loose")
        let folderPlan = try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: [target]))
        await store.openDroppedWorkspace(folderPlan, target: files)
        XCTAssertFalse(store.currentFiles === files); XCTAssertEqual(store.currentFiles.root, target.path)
        XCTAssertEqual(files.documents.count, 2)
    }
    @MainActor func testServerArrowsAndExplorerCopyAreScopedToTheirFirstResponder() async throws {
        let (store, root) = try fixture(); defer { store.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
        let list = BrowserListKeyView(); list.store = store
        window.contentView = NSView(); window.contentView!.addSubview(list)
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        let a = ServerProfile(name: "A", host: "a.invalid"), b = ServerProfile(name: "B", host: "b.invalid")
        store.profiles = [a,b]; list.serverIDs = [a.id,b.id]; store.selectWorkspace(a.id); list.focusList()
        XCTAssertTrue(store.handleServerKey(event(125))); XCTAssertEqual(store.selectedProfileID,b.id)
        XCTAssertTrue(window.firstResponder === list)
        XCTAssertTrue(store.handleServerKey(event(126))); XCTAssertEqual(store.selectedProfileID,a.id)
        let input = NSTextView(); window.contentView!.addSubview(input); window.makeFirstResponder(input)
        XCTAssertFalse(store.handleServerKey(event(125))); XCTAssertEqual(store.selectedProfileID,a.id)
        store.selectWorkspace(nil)
        let files = store.currentFiles; files.enabled = true; list.workspace = files
        try "a".write(to: root.appendingPathComponent("alpha.py"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("beta.py"), atomically: true, encoding: .utf8)
        await files.prepare(store: store); await files.navigate(root.path)
        list.focusList(); XCTAssertTrue(store.handleExplorerKey(event(125)))
        let selected = try XCTUnwrap(files.selectedEntry)
        let clipboard = NSPasteboard(name: .init(UUID().uuidString))
        let provider = WorkspaceDragDrop.provider(for: selected, profileID: nil)
        let dragItems = try await WorkspaceDragDrop.items(from: [provider])
        clipboard.setData(try JSONEncoder().encode(dragItems), forType: .init(WorkspaceDropItem.typeIdentifier))
        XCTAssertEqual(try store.clipboardEntries(clipboard), dragItems)
        window.makeFirstResponder(input)
        XCTAssertFalse(store.handleExplorerKey(event(8,.command)))
        XCTAssertFalse(store.handleExplorerKey(event(51,.command)))
    }
    @MainActor func testBackgroundActivationCannotReplaceAnExplicitDirectoryRequest() async throws {
        let (store, root) = try fixture(); defer { store.shutdown() }
        let child = root.appendingPathComponent("chosen"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let files = store.currentFiles; files.enabled = true; await files.prepare(store: store)
        let opening = Task { await files.navigate(child.path) }
        await Task.yield()
        await files.activate(store: store)
        await opening.value
        XCTAssertEqual(files.root, child.path)
    }
    @MainActor func testDropPathQuotesShellCharactersAndCancelClearsReorderIndicator() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let path = "/tmp/a ' $(touch nope);文.py"
        let item = WorkspaceDropItem(profileID: nil, entry: WorkspaceEntry(path: path,name: "a",directory: false,size: 0,modified: 0))
        XCTAssertEqual(try WorkspaceDragDrop.terminalText([item], profileID: nil), SSHArguments.quote(path) + " ")
        var malicious = item; malicious.entry.path = "/tmp/file\nexit"
        XCTAssertThrowsError(try WorkspaceDragDrop.terminalText([malicious], profileID: nil))
        var remote = item; remote.profileID = UUID()
        XCTAssertThrowsError(try WorkspaceDragDrop.terminalText([remote], profileID: UUID()))
        let a = ServerProfile(name: "A",host: "a.invalid"), b = ServerProfile(name: "B",host: "b.invalid")
        store.profiles = [a,b]; _ = store.dragProvider(.server(a.id))
        let drag = try XCTUnwrap(store.activeDrag)
        XCTAssertTrue(store.canDrop(drag, on: .server(b.id), intent: .after))
        store.endDrag(); XCTAssertNil(store.activeDrag); XCTAssertNil(store.dragEndMonitor)
        XCTAssertFalse(store.canDrop(drag, on: .server(b.id), intent: .after))
    }
    @MainActor func testSplitUsesChangedLiveShellDirectoryInsteadOfExplorerRoot() async throws {
        let (store, root) = try fixture(); defer { store.shutdown() }
        let child = root.appendingPathComponent("当前 ' folder"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let childInode = try FileManager.default.attributesOfItem(atPath: child.path)[.systemFileNumber] as? NSNumber
        func isChild(_ path: String?) -> Bool {
            guard let path, let inode = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber else { return false }
            return inode == childInode
        }
        store.currentFiles.root = root.path; store.openWorkspaceTerminal()
        let original = try XCTUnwrap(store.activeSession)
        original.terminal.send(txt: "cd -- " + SSHArguments.quote(child.path) + "\n")
        let until = Date().addingTimeInterval(5)
        while !isChild(original.effectiveDirectory) && Date() < until { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(isChild(original.effectiveDirectory))
        let actualChild = original.effectiveDirectory
        store.splitTerminal(.columns)
        let split = try XCTUnwrap(store.activeSession)
        XCTAssertNotEqual(original.id,split.id); XCTAssertEqual(split.workingDirectory,actualChild)
        XCTAssertEqual(original.tabTitle, root.lastPathComponent)
        XCTAssertEqual(split.tabTitle, child.lastPathComponent)
        XCTAssertEqual(store.currentFiles.root,root.path)
        let later = Date().addingTimeInterval(3)
        while !isChild(split.effectiveDirectory) && Date() < later { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(isChild(split.effectiveDirectory))
    }
    @MainActor func testReconnectRestoresAllDisconnectedServerPanesAcrossDirectoriesOnly() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let profile = ServerProfile(name: "A", host: "a.invalid"), other = ServerProfile(name: "B", host: "b.invalid")
        store.profiles = [profile,other]
        let firstFiles = store.files(for: profile); firstFiles.root = "/project"
        let secondFiles = store.directoryWorkspaceForPath("/other", profile: profile)
        func add(_ p: ServerProfile, files: FileWorkspace, dead: Bool, title: String) throws -> TerminalSession {
            let session = try TerminalSession(profile:p,title:title,history:store.history,workingDirectory:files.root)
            session.directoryWorkspaceID = files.directoryID; session.ended = dead
            session.currentDirectory = files.root + "/child"; session.customTitle = "自定义 " + title; session.tabWidth = 222
            store.sessions.append(session); store.registerTerminal(session); return session
        }
        let a = try add(profile,files:firstFiles,dead:true,title:"1"), b = try add(profile,files:firstFiles,dead:true,title:"2")
        let c = try add(profile,files:secondFiles,dead:true,title:"3"), live = try add(profile,files:secondFiles,dead:false,title:"live")
        let foreign = try add(other,files:store.files(for:other),dead:true,title:"foreign")
        let scope = store.terminalScope(of:a); var layout = store.arrangement(in:scope); layout.split(a.id,adding:b.id,axis:.rows); store.terminalLayouts[scope] = layout
        store.selectSession(a); store.reconnect(a)
        XCTAssertEqual(store.sessions.count,5)
        XCTAssertTrue(store.sessions.contains { $0 === live }); XCTAssertTrue(store.sessions.contains { $0 === foreign })
        XCTAssertFalse(store.sessions.contains { [a.id,b.id,c.id].contains($0.id) })
        XCTAssertEqual(store.arrangement(in:scope).groups.count,1)
        XCTAssertEqual(store.arrangement(in:scope).sessionIDs.count,2)
        XCTAssertEqual(store.activeSession?.customTitle,a.customTitle)
        XCTAssertEqual(store.activeSession?.workingDirectory,"/project/child")
        XCTAssertTrue(store.sessions.filter { ![live.id,foreign.id].contains($0.id) }.allSatisfy { $0.tabWidth == 222 })
        let replacementC = try XCTUnwrap(store.sessions.first { $0.customTitle == c.customTitle })
        XCTAssertEqual(replacementC.directoryWorkspaceID,secondFiles.directoryID)
        XCTAssertEqual(replacementC.workingDirectory,"/other/child")
    }
}

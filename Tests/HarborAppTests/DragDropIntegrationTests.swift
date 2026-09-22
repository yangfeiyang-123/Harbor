import XCTest
import AppKit
import UniformTypeIdentifiers
import HarborCore
@testable import HarborSSH

final class DragDropIntegrationTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-drop-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() -> UserDefaults {
        let name = "app.harbor.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testNativeFinderURLAndHarborProvidersRoundTrip() async throws {
        let root = try temporary(), file = root.appendingPathComponent("中文 folder ' quote.md")
        try Data("# original".utf8).write(to: file)
        let finder = NSItemProvider(object: file as NSURL)
        let local = try await WorkspaceDragDrop.plan(from: [finder])
        XCTAssertNil(local.profileID); XCTAssertEqual(local.files.first?.path, file.path)
        let profileID = UUID()
        let server = WorkspaceDragDrop.provider(for: local.files[0], profileID: profileID)
        XCTAssertFalse(server.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let remote = try await WorkspaceDragDrop.plan(from: [server])
        XCTAssertEqual(remote.profileID, profileID); XCTAssertEqual(remote.files, local.files)
        let ownLocal = WorkspaceDragDrop.provider(for: local.files[0], profileID: nil)
        XCTAssertTrue(ownLocal.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let second = try await WorkspaceDragDrop.plan(from: [ownLocal])
        XCTAssertNil(second.profileID); XCTAssertEqual(second.files, local.files)
    }
    @MainActor func testDropSwitchesToLocalWithoutLosingUnsavedDocuments() async throws {
        let root = try temporary(), prefs = defaults()
        let store = AppStore(historyRoot: root.appendingPathComponent("history"), workspaceDefaults: prefs)
        let profile = ServerProfile(name: "remote", host: "example.invalid")
        store.profiles = [profile]; store.selectWorkspace(profile.id)
        let remote = store.currentFiles
        let draft = WorkspaceDocument(WorkspaceEntry(path: "/remote/draft.py", name: "draft.py", directory: false, size: 2, modified: 0))
        draft.savedText = "original"; draft.text = "unsaved remote work"; remote.documents = [draft]; remote.selection = draft.id
        let first = root.appendingPathComponent("first.py"), secondFolder = root.appendingPathComponent("other folder")
        try Data("print('first')".utf8).write(to: first)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: false)
        let second = secondFolder.appendingPathComponent("second.md"); try Data("# Second".utf8).write(to: second)
        await store.openDroppedWorkspace(try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: [first])))
        XCTAssertNil(store.selectedProfileID)
        XCTAssertEqual(store.currentFiles.currentDocument?.text, "print('first')")
        XCTAssertTrue(store.currentFiles.enabled)
        let localDraft = try XCTUnwrap(store.currentFiles.currentDocument); localDraft.text = "unsaved local work"
        await store.openDroppedWorkspace(try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: [second])))
        XCTAssertEqual(store.currentFiles.root, secondFolder.path)
        XCTAssertEqual(store.currentFiles.currentDocument?.text, "# Second")
        XCTAssertEqual(localDraft.text, "unsaved local work"); XCTAssertTrue(localDraft.dirty)
        XCTAssertEqual(remote.currentDocument?.text, "unsaved remote work"); XCTAssertTrue(draft.dirty)
        XCTAssertTrue(store.hasUnsavedFiles)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "print('first')")
        let restored = FileWorkspace(profile: nil, defaults: prefs)
        XCTAssertEqual(restored.root, root.path)
        XCTAssertEqual(restored.savedOpenPaths, [first.path])
        let other = FileWorkspace(profile: nil, defaults: prefs, directoryID: store.selectedDirectoryID)
        XCTAssertEqual(other.root, secondFolder.path)
        XCTAssertEqual(other.savedOpenPaths, [second.path])
        XCTAssertEqual(store.directoryWorkspaces(for: nil).count, 2)
        store.selectDirectory(profileID: nil, directoryID: nil)
        XCTAssertTrue(store.currentFiles.currentDocument === localDraft)
    }
    @MainActor func testRemovedServerDropCannotOpenAnotherServer() async throws {
        let store = AppStore(historyRoot: try temporary(), workspaceDefaults: defaults())
        let profile = ServerProfile(name: "current", host: "example.invalid")
        store.profiles = [profile]; store.selectWorkspace(profile.id)
        let missing = WorkspaceDropItem(profileID: UUID(), entry: WorkspaceEntry(path: "/remote", name: "remote", directory: true, size: 0, modified: 0))
        await store.openDroppedWorkspace(try WorkspaceDropPlan(items: [missing]))
        XCTAssertEqual(store.selectedProfileID, profile.id)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.currentFiles.enabled)
    }
    @MainActor func testAllTenStoredIconsExistOnMacOS() {
        XCTAssertEqual(ServerIcons.symbols.count, 10)
        for symbol in ServerIcons.symbols { XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol) }
    }
}

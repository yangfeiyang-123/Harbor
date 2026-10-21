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
        let defaults = TestDefaults.suite(name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
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

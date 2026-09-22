import XCTest
@testable import HarborCore

final class WorkspaceSearchTests: XCTestCase {
    private func fixture() throws -> (URL, WorkspaceFileService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-search-" + UUID().uuidString)
        let cache = root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appendingPathComponent("Sources/HarborSSH/Resources/WorkspaceRuntime/files.py"), encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, WorkspaceFileService(profile: nil, socket: nil, script: script, cache: cache))
    }
    func testFindsUnexpandedNestedFilesAndContentWithUTF16Positions() async throws {
        let (root, service) = try fixture()
        let nested = root.appendingPathComponent("src/实验 ' $(no)")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let text = "class Robot:\n    print('🤖 Straße NEEDLE')\n    print('needle')\n"
        try Data(text.utf8).write(to: nested.appendingPathComponent("controller.py"))
        let names = try await service.search("srcctrlpy", root: root.path, content: false)
        XCTAssertEqual(names.hits.map(\.entry.name), ["controller.py"])
        let found = try await service.search("needle", root: root.path, content: true)
        XCTAssertEqual(found.hits.map(\.line), [2, 3])
        XCTAssertEqual(found.hits.first?.column, 22)
        let sensitive = try await service.search("NEEDLE", root: root.path, content: true, caseSensitive: true)
        XCTAssertEqual(sensitive.hits.count, 1)
        XCTAssertEqual(sensitive.hits.first?.column, found.hits.first?.column)
        XCTAssertFalse(found.truncated)
    }
    func testSearchBoundsSkipHiddenGeneratedBinaryLargeAndSymlinkFiles() async throws {
        let (root, service) = try fixture()
        for name in [".hidden", "node_modules", "visible"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("needle".utf8).write(to: root.appendingPathComponent(name + "/match.py"))
        }
        try Data([0, 110, 101, 101, 100, 108, 101]).write(to: root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("large"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.py"), withDestinationURL: root.appendingPathComponent("visible/match.py"))
        let found = try await service.search("needle", root: root.path, content: true)
        XCTAssertEqual(found.hits.map(\.relative), ["visible/match.py"])
        XCTAssertEqual(found.skipped, 2)
        let hidden = try await service.search("needle", root: root.path, content: true, hidden: true)
        XCTAssertEqual(hidden.hits.count, 2)
        let cacheFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".cache").path)
        XCTAssertTrue(cacheFiles.isEmpty)
    }
    func testResultLimitAndCancelledSearchDoNotLeaveTemporaryOutput() async throws {
        let (root, service) = try fixture()
        try Data(String(repeating: "needle\n", count: 300).utf8).write(to: root.appendingPathComponent("many.txt"))
        let result = try await service.search("needle", root: root.path, content: true)
        XCTAssertEqual(result.hits.count, 200); XCTAssertTrue(result.truncated)
        let task = Task { try await service.search("needle", root: root.path, content: true) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search must not complete") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".cache").path).isEmpty)
    }
}

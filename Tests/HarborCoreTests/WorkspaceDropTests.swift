import XCTest
@testable import HarborCore

final class WorkspaceDropTests: XCTestCase {
    func testLegacyProfilesMigrateOnceAndNewIconsStayStable() throws {
        let original = ServerProfile(name: "Legacy", host: "legacy")
        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("iconSymbol"))
        var profiles = [try JSONDecoder().decode(ServerProfile.self, from: data)] + (1..<10).map { ServerProfile(name: "Server \($0)", host: "host\($0)") }
        XCTAssertTrue(ServerIcons.assignMissing(in: &profiles))
        XCTAssertEqual(Set(profiles.compactMap(\.iconSymbol)).count, 10)
        let stable = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.iconSymbol) })
        profiles.reverse()
        XCTAssertFalse(ServerIcons.assignMissing(in: &profiles))
        profiles.append(ServerProfile(name: "Eleven", host: "eleven"))
        XCTAssertTrue(ServerIcons.assignMissing(in: &profiles))
        for profile in profiles.dropLast() { XCTAssertEqual(profile.iconSymbol, stable[profile.id]!) }
        let saved = try JSONDecoder().decode([ServerProfile].self, from: JSONEncoder().encode(profiles))
        XCTAssertEqual(saved, profiles)
        profiles[0].iconSymbol = "unsupported-symbol"
        XCTAssertTrue(ServerIcons.assignMissing(in: &profiles))
        XCTAssertTrue(ServerIcons.symbols.contains(profiles[0].displayIcon))
    }

    func testFinderFolderAndFileDropKeepsUnicodeAndNeverWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("工作 目录")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("a ' $(noop).md"), data = Data("# 保留原文".utf8)
        try data.write(to: file)
        let folderPlan = try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: [folder]))
        XCTAssertNil(folderPlan.profileID); XCTAssertEqual(folderPlan.root, folder.path); XCTAssertTrue(folderPlan.files.isEmpty)
        let filePlan = try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: [file, file]))
        XCTAssertEqual(filePlan.root, folder.path); XCTAssertEqual(filePlan.files.map(\.path), [file.path])
        XCTAssertEqual(try Data(contentsOf: file), data)
        let link = root.appendingPathComponent("shortcut.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linked = try WorkspaceDropPlan.localItems(urls: [link])[0]
        XCTAssertEqual(linked.entry.path, link.path); XCTAssertEqual(linked.entry.size, Int64(data.count))
        XCTAssertThrowsError(try WorkspaceDropPlan.localItems(urls: [URL(string: "https://example.com/a.md")!]))
        XCTAssertThrowsError(try WorkspaceDropPlan.localItems(urls: [URL(string: "file://another-host/tmp/a.md")!]))
        XCTAssertThrowsError(try WorkspaceDropPlan.localItems(urls: [root.appendingPathComponent("missing")]))
    }

    func testRemoteDropRetainsServerIdentityAndRejectsMixedSources() throws {
        let server = UUID(), path = "/data/中文 workspace/main.py"
        let item = WorkspaceDropItem(profileID: server, entry: WorkspaceEntry(path: path, name: "main.py", directory: false, size: 12, modified: 0))
        let decoded = try JSONDecoder().decode(WorkspaceDropItem.self, from: JSONEncoder().encode(item))
        let plan = try WorkspaceDropPlan(items: [decoded])
        XCTAssertEqual(plan.profileID, server); XCTAssertEqual(plan.root, "/data/中文 workspace")
        var local = item; local.profileID = nil
        XCTAssertThrowsError(try WorkspaceDropPlan(items: [item, local]))
        var relative = item; relative.entry.path = "../file.py"
        XCTAssertThrowsError(try WorkspaceDropPlan(items: [relative]))
        XCTAssertThrowsError(try WorkspaceDropPlan(items: []))
    }
}

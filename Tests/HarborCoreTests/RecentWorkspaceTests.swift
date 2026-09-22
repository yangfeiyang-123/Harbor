import XCTest
@testable import HarborCore

final class RecentWorkspaceTests: XCTestCase {
    func testServerGroupsFollowSidebarOrderAndSearchUsesCurrentServerNames() {
        let first = ServerProfile(name: "Renamed Server", host: "a.invalid"), second = ServerProfile(name: "Research", host: "b.invalid")
        let entries = [
            RecentWorkspace(serverID: first.id, serverName: "Old Name", directory: "/old", openedAt: Date(timeIntervalSince1970: 1)),
            RecentWorkspace(serverID: nil, serverName: "本机", directory: "/Users/demo/项目"),
            RecentWorkspace(serverID: second.id, serverName: "Research", directory: "/same"),
            RecentWorkspace(serverID: first.id, serverName: "Old Name", directory: "/same", openedAt: Date(timeIntervalSince1970: 2))
        ]
        let groups = RecentWorkspaceGroup.make(entries, profiles: [second, first])
        XCTAssertEqual(groups.map(\.name), ["Research", "Renamed Server", "Local"])
        XCTAssertEqual(groups[1].entries.map(\.directory), ["/same", "/old"])
        XCTAssertEqual(groups[2].entries.first?.directory, "/Users/demo/项目")
        XCTAssertEqual(RecentWorkspaceGroup.make(entries, profiles: [first, second], query: "renamed").map(\.serverID), [first.id])
        XCTAssertEqual(RecentWorkspaceGroup.make(entries, profiles: [first, second], query: "same").count, 2)
        XCTAssertTrue(RecentWorkspaceGroup.make(entries, profiles: [first, second], query: "missing").isEmpty)
    }
    func testRecentLocationsDeduplicateByServerAndDirectoryAndKeepNewest() throws {
        let a = UUID(), b = UUID(), start = Date(timeIntervalSince1970: 1000)
        let entries = [
            RecentWorkspace(serverID: a, serverName: "A", directory: "/work/project/", openedAt: start),
            RecentWorkspace(serverID: a, serverName: "A new", directory: "/work/project", openedAt: start.addingTimeInterval(10)),
            RecentWorkspace(serverID: b, serverName: "B", directory: "/work/project", openedAt: start),
            RecentWorkspace(serverID: nil, serverName: "Local", directory: "/work/project", openedAt: start)
        ]
        let merged = RecentWorkspace.merged(entries, available: [a, b])
        XCTAssertEqual(merged.count, 3); XCTAssertEqual(merged[0].serverName, "A new")
        XCTAssertEqual(merged[0].title, "project")
        XCTAssertEqual(RecentWorkspace.merged(entries, available: [a]).count, 2)
        XCTAssertEqual(try JSONDecoder().decode([RecentWorkspace].self, from: JSONEncoder().encode(merged)), merged)
        let many = (0..<30).map { RecentWorkspace(serverID: a, serverName: "A", directory: "/work/\($0)", openedAt: start.addingTimeInterval(Double($0))) }
        XCTAssertEqual(RecentWorkspace.merged(many, available: [a]).count, 12)
        XCTAssertEqual(RecentWorkspace.merged(many, available: [a]).first?.directory, "/work/29")
    }
    func testLegacyMigrationSkipsFailuresAndPreservesTmuxAndDirectory() {
        let a = UUID()
        var success = SessionRecord(serverID: a, serverName: "A", title: "A 1", tmuxName: "harbor-test", workingDirectory: "/work/中文")
        success.exitCode = 0
        var failed = SessionRecord(serverID: a, serverName: "A", title: "failed", workingDirectory: "/failed")
        failed.exitCode = 255
        let removed = SessionRecord(serverID: UUID(), serverName: "removed", title: "removed")
        let migrated = RecentWorkspace.migrate([failed, removed, success], available: [a])
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].directory, "/work/中文")
        XCTAssertEqual(migrated[0].tmuxName, "harbor-test")
        XCTAssertEqual(migrated[0].openedAt, success.startedAt)
    }
}

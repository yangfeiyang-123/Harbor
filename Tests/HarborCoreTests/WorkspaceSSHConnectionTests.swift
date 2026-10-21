import XCTest
@testable import HarborCore

final class WorkspaceSSHConnectionTests: XCTestCase {
    private func fixture() throws -> (WorkspaceSSHConnection, URL) {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: marker)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        return (WorkspaceSSHConnection(profile: ServerProfile(name: "Test", host: "test.invalid", imported: true), socket: marker.path), marker)
    }
    func testSessionLimitRetriesOnSeparateMasterAndReusesIt() async throws {
        let (connection, marker) = try fixture()
        var calls: [[String]] = []
        try await connection.run(command: "test command") { args in
            calls.append(args)
            if calls.count == 1 { throw WorkspaceError.message("mux_client_request_session: session request failed: Session open refused by peer\nConnection closed by UNKNOWN port 65535") }
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains(marker.path))
        XCTAssertTrue(calls[1].contains(connection.fileSocket))
        XCTAssertFalse(calls[1].contains("ProxyCommand=false"))
        XCTAssertTrue(calls[1].contains("BatchMode=yes"))
        try await connection.run(command: "next") { args in XCTAssertTrue(args.contains(connection.fileSocket)) }
    }
    func testInterruptedWriteIsNeverRepeated() async throws {
        let (connection, _) = try fixture()
        var calls = 0
        do {
            try await connection.run(command: "save file") { _ in calls += 1; throw WorkspaceError.message("Connection reset by peer") }
            XCTFail("Should fail without replaying the write")
        } catch { XCTAssertEqual(calls, 1) }
        XCTAssertFalse(WorkspaceSSHConnection.refusedBeforeExecution("Permission denied"))
        XCTAssertFalse(WorkspaceSSHConnection.refusedBeforeExecution("Connection closed by UNKNOWN port 65535"))
    }
    func testMissingMasterUsesFileConnectionWithoutTerminalAuthenticationPrompt() async throws {
        let (connection, marker) = try fixture()
        try FileManager.default.removeItem(at: marker)
        try await connection.run(command: "list") { args in
            XCTAssertTrue(args.contains(connection.fileSocket)); XCTAssertFalse(args.contains(marker.path))
            XCTAssertTrue(args.contains("ControlPersist=60"))
        }
    }
    func testConnectionHealthDoesNotConsumeRemoteSessionSlot() {
        let args = SSHArguments.check(ServerProfile(name: "Test", host: "test.invalid"), socket: "/tmp/socket")
        XCTAssertTrue(args.contains("-O")); XCTAssertTrue(args.contains("check"))
        XCTAssertFalse(args.contains("HARBOR_SSH_READY")); XCTAssertFalse(args.contains("-T"))
    }
}

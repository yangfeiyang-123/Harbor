import XCTest
import HarborCore
@testable import HarborSSH

final class FileConnectionRecoveryRemoteTests: XCTestCase {
    @MainActor func testExplorerOpensWhenTerminalMasterRefusesAdditionalSessions() async throws {
        guard let host = ProcessInfo.processInfo.environment["HARBOR_QA_SSH_HOST"] else { throw XCTSkip("Set HARBOR_QA_SSH_HOST for an authorized read-only server check") }
        let root = URL(fileURLWithPath: "/tmp/harbor-file-slots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ServerProfile(name: "File session QA", host: host, imported: true)
        let socket = root.appendingPathComponent("ssh").path
        let start = await ProcessRunner.run("/usr/bin/ssh", ["-o", "BatchMode=yes"] + SSHArguments.common(profile, socket: socket) + ["-N", "-f", "--", host], timeout: 20)
        XCTAssertTrue(start.succeeded, start.output)
        guard start.succeeded else { return }
        var held: [Process] = []
        let files = FileWorkspace(profile: profile, defaults: TestDefaults.suite(root.lastPathComponent)!)
        let script = try String(contentsOf: AppResources.directory("WorkspaceRuntime").appendingPathComponent("files.py"), encoding: .utf8)
        files.service = WorkspaceFileService(profile: profile, socket: socket, script: script, cache: root)
        let fileSocket = WorkspaceSSHConnection(profile: profile, socket: socket).fileSocket
        func cleanup() async {
            for process in held where process.isRunning { process.terminate() }
            for path in [fileSocket, socket] {
                _ = await ProcessRunner.run("/usr/bin/ssh", ["-S", path, "-O", "exit", "--", host], timeout: 5)
            }
            UserDefaults.standard.removePersistentDomain(forName: root.lastPathComponent)
        }
        do {
            // MaxSessions is normally 10. These are unique QA channels on our
            // own master; no existing user session or configuration is touched.
            for _ in 0..<10 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = SSHArguments.probe(profile, socket: socket, command: "sleep 45")
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); held.append(process)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let refused = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket), timeout: 10)
            XCTAssertTrue(WorkspaceSSHConnection.refusedBeforeExecution(refused.output), refused.output)
            let health = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.check(profile, socket: socket), timeout: 5)
            XCTAssertTrue(health.succeeded, "A session limit must not mark the server offline")
            await files.navigate(ProcessInfo.processInfo.environment["HARBOR_QA_REMOTE_DIRECTORY"] ?? "~")
            XCTAssertNil(files.error)
            XCTAssertFalse(files.root.isEmpty)
            XCTAssertTrue(held.allSatisfy(\.isRunning), "Browsing files must leave the occupied terminal channels alive")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileSocket))
            await cleanup()
        } catch { await cleanup(); throw error }
    }
}

import XCTest
import HarborCore
@testable import HarborSSH

private final class TransferSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WorkspaceTransferProgress] = []
    func add(_ value: WorkspaceTransferProgress) { lock.lock(); values.append(value); lock.unlock() }
    var all: [WorkspaceTransferProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

final class RemoteFileTransferProgressTests: XCTestCase {
    func testSSHUploadDownloadProgressAndCollisionSafeRoundTrip() async throws {
        guard let host = ProcessInfo.processInfo.environment["HARBOR_QA_SSH_HOST"] else { throw XCTSkip("Authorized live transfer check requires HARBOR_QA_SSH_HOST") }
        let fm = FileManager.default, name = "harbor-transfer-qa-" + UUID().uuidString
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(name), remoteRoot = "/tmp/" + name
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let socket = root.appendingPathComponent("ssh").path
        let profile = ServerProfile(name: "Transfer QA", host: host, imported: true)
        let connected = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.common(profile, socket: socket) + ["-o", "BatchMode=yes", "-T", "--", host, "true"], timeout: 30)
        XCTAssertTrue(connected.succeeded, connected.output)
        guard connected.succeeded else { return }
        var created = false
        func cleanup() async {
            if created {
                let command = "python3 -c " + SSHArguments.quote("import shutil; shutil.rmtree(" + "'" + remoteRoot + "'" + ")")
                let removed = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket, command: command), timeout: 15)
                XCTAssertTrue(removed.succeeded, "Could not remove QA fixture: " + remoteRoot)
            }
            _ = await ProcessRunner.run("/usr/bin/ssh", ["-S", socket, "-O", "exit", "--", host], timeout: 5)
        }
        do {
            let script = try String(contentsOf: AppResources.directory("WorkspaceRuntime").appendingPathComponent("files.py"), encoding: .utf8)
            let cache = root.appendingPathComponent("cache"), target = root.appendingPathComponent("download")
            for directory in [cache, target] { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
            let remote = WorkspaceFileService(profile: profile, socket: socket, script: script, cache: cache,
                relay: { @Sendable in await ManagedRelay.port(for: profile) })
            let local = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
            try await remote.create(name: name, parent: "/tmp", directory: true); created = true
            let source = root.appendingPathComponent("Screenshot ' upload.png")
            let bytes = Data((0..<262_144).map { UInt8($0 % 251) }); try bytes.write(to: source)
            let upload = try await local.exportItem(source.path), sent = TransferSamples(), received = TransferSamples()
            let destination = try await remote.importItem(upload, name: source.lastPathComponent, parent: remoteRoot, progress: { sent.add($0) })
            let archiveSize = (try fm.attributesOfItem(atPath: upload.path)[.size] as! NSNumber).int64Value
            XCTAssertEqual(sent.all.first?.bytes, 0)
            XCTAssertEqual(sent.all.last, WorkspaceTransferProgress(.finalizing, bytes: archiveSize, total: archiveSize))
            let second = try await remote.importItem(upload, name: source.lastPathComponent, parent: remoteRoot)
            XCTAssertNotEqual(destination, second, "An existing screenshot must not be overwritten")
            let download = try await remote.exportItem(destination, progress: { received.add($0) })
            let receivedSize = (try fm.attributesOfItem(atPath: download.path)[.size] as! NSNumber).int64Value
            XCTAssertEqual(received.all.last?.bytes, receivedSize)
            XCTAssertNil(received.all.last?.total, "Streaming folder downloads must not invent a total")
            let restored = try await local.importItem(download, name: source.lastPathComponent, parent: target.path)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored)), bytes)
            let listing = try await remote.list(remoteRoot)
            XCTAssertEqual(listing.entries.count, 2)
            await cleanup()
        } catch { await cleanup(); throw error }
    }
}

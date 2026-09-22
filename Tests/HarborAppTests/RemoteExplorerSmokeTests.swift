import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class RemoteExplorerSmokeTests: XCTestCase {
    @MainActor func testLiveRemoteSplitAndServerWideReconnect() async throws {
        guard let host = ProcessInfo.processInfo.environment["HARBOR_QA_SSH_HOST"], !host.isEmpty else { throw XCTSkip("Set HARBOR_QA_SSH_HOST for an authorized remote smoke check") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-ssh-smoke-" + UUID().uuidString)
        let suite = "app.harbor.ssh-smoke." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        defer { store.shutdown(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let profile = ServerProfile(name: "Harbor smoke", host: host)
        store.profiles = [profile]; store.selectWorkspace(profile.id)
        _ = store.openTerminal(profile, workingDirectory: "/", useWorkspaceDirectory: false)
        let original = try XCTUnwrap(store.activeSession)
        func wait(_ seconds: TimeInterval = 20, until condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(seconds)
            while !condition() && Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertTrue(condition())
        }
        try await wait { original.ready && original.remoteShellPID != nil }
        guard original.ready, original.remoteShellPID != nil else { return }
        original.terminal.send(txt: "cd /tmp\n")
        try await Task.sleep(nanoseconds: 300_000_000)
        await store.refreshTerminalDirectories([original])
        XCTAssertEqual(original.currentDirectory, "/tmp")
        store.splitTerminal(.columns, session: original)
        try await wait { store.sessions.count == 2 && store.sessions.allSatisfy { $0.ready && $0.remoteShellPID != nil } }
        let split = try XCTUnwrap(store.sessions.first { $0 !== original })
        XCTAssertEqual(split.workingDirectory, "/tmp")
        await store.refreshTerminalDirectories([split]); XCTAssertEqual(split.currentDirectory, "/tmp")
        original.rename(to: "QA directory"); split.rename(to: "QA split")
        let oldIDs = Set(store.sessions.map(\.id)), scope = store.terminalScope(of: original)
        // Only these test-owned SSH channels are stopped. The shared master and
        // the user's application sessions are never terminated.
        original.stop(); split.stop(); store.reconnect(original)
        try await wait { store.sessions.count == 2 && store.sessions.allSatisfy { $0.ready && $0.remoteShellPID != nil } }
        XCTAssertTrue(oldIDs.isDisjoint(with: Set(store.sessions.map(\.id))))
        XCTAssertEqual(store.arrangement(in: scope).groups.count, 1)
        XCTAssertEqual(Set(store.sessions.compactMap(\.customTitle)), ["QA directory", "QA split"])
        await store.refreshTerminalDirectories(store.sessions)
        XCTAssertTrue(store.sessions.allSatisfy { $0.currentDirectory == "/tmp" })
        let files = store.currentFiles; await files.prepare(store: store)
        try await verifyRemoteFileOperations(try XCTUnwrap(files.service), localRoot: root)
    }

    // Exercise the production SSH transport and Linux filesystem operations on
    // disposable fixtures, including multi-chunk binary uploads/downloads.
    @MainActor private func verifyRemoteFileOperations(_ service: WorkspaceFileService, localRoot: URL) async throws {
        let name = "harbor-files-smoke-" + UUID().uuidString, remoteRoot = "/tmp/" + name
        try await service.create(name: name, parent: "/tmp", directory: true)
        let cleanup = "python3 -c " + SSHArguments.quote("import shutil; shutil.rmtree(" + "'" + remoteRoot + "'" + ")")
        func removeFixture() async {
            let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(service.profile!, socket: service.socket!, command: cleanup), timeout: 10)
            XCTAssertTrue(result.succeeded, "Could not clean the disposable remote fixture: " + remoteRoot)
        }
        do {
            let source = localRoot.appendingPathComponent("source"), cache = localRoot.appendingPathComponent("transfers")
            for folder in [source, cache] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
            let bytes = Data((0..<3_200_000).map { UInt8($0 % 251) })
            let filename = "视频 ' file.mp4"
            try bytes.write(to: source.appendingPathComponent(filename))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: filename)
            let local = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
            let upload = try await local.exportItem(source.path)
            let uploaded = try await service.importItem(upload, name: "上传 folder", parent: remoteRoot)
            let copied = try await service.operate("copy", path: uploaded, parent: remoteRoot)
            let renamed = try await service.operate("rename", path: copied, parent: remoteRoot, name: "重命名")
            try await service.create(name: "destination", parent: remoteRoot, directory: true)
            let moved = try await service.operate("move", path: renamed, parent: remoteRoot + "/destination")
            let download = try await service.exportItem(moved)
            let downloaded = try await local.importItem(download, name: "downloaded", parent: localRoot.path)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: downloaded).appendingPathComponent(filename)), bytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: downloaded + "/link"), filename)
            let listing = try await service.list(remoteRoot)
            XCTAssertEqual(Set(listing.entries.map(\.name)), ["上传 folder", "destination"])
            // Keep this test's recoverable Trash entirely in its fixture.
            let trashService = WorkspaceFileService(profile: service.profile, socket: service.socket,
                script: "import os\nos.environ['HOME'] = '" + remoteRoot + "/.home'\n" + service.script, cache: service.cache)
            let trashed = try await trashService.operate("trash", path: moved)
            XCTAssertTrue(trashed.hasPrefix(remoteRoot + "/.home/.local/share/Harbor/Trash/deleted-"))
            let trashListing = try await service.list(trashed)
            XCTAssertEqual(Set(trashListing.entries.map(\.name)), [filename, "link"])
        } catch { await removeFixture(); throw error }
        await removeFixture()
    }
}

import XCTest
@testable import HarborCore

final class WorkspaceFileTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-files-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testLocalListingUnicodePathsHiddenFilesAndDirectories() async throws {
        let root = try temporary(), cache = try temporary()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("实验 目录"), withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a ' $(uname).py"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
        let listing = try await service.list(root.path)
        XCTAssertEqual(listing.entries.map(\.name), ["实验 目录", "a ' $(uname).py"])
        XCTAssertTrue(listing.entries[0].directory)
        let hidden = try await service.list(root.path, showHidden: true)
        XCTAssertEqual(hidden.entries.count, 3)
        let file = try await service.materialize(listing.entries[1], limit: 100)
        XCTAssertEqual(try Data(contentsOf: file), Data("hello".utf8))
    }
    func testLocalSaveRejectsConflictAndPreservesSymlinkAndMode() async throws {
        let root = try temporary(), cache = try temporary(), target = root.appendingPathComponent("target.py"), link = root.appendingPathComponent("link.py")
        let initial = Data("print('初始')\n".utf8)
        try initial.write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
        _ = try await service.save(path: link.path, text: "print('changed')\n", expectedDigest: WorkspacePath.digest(initial))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "print('changed')\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o755)
        do { _ = try await service.save(path: link.path, text: "overwrite", expectedDigest: WorkspacePath.digest(initial)); XCTFail("Must reject conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Another application changed")) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "print('changed')\n")
    }
    func testCreateDoesNotOverwriteAndRejectsTraversal() async throws {
        let root = try temporary(), cache = try temporary(), service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: try temporary())
        _ = cache
        try await service.create(name: "new.py", parent: root.path, directory: false)
        try Data("keep".utf8).write(to: root.appendingPathComponent("new.py"))
        do { try await service.create(name: "new.py", parent: root.path, directory: false); XCTFail("Must not overwrite") } catch { }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.py"), encoding: .utf8), "keep")
        for name in ["../escape", "/absolute", "", ".", "..", "new\nline"] { XCTAssertThrowsError(try WorkspacePath.child(name, in: root.path)) }
    }
    func testTerminalDirectoryIsSafelyQuotedAndLegacyRecordLoads() throws {
        let profile = ServerProfile(name: "test", host: "host")
        let path = "/data/实验 ' $(touch /tmp/nope)"
        let normal = SSHArguments.terminal(profile, socket: "/tmp/socket", workingDirectory: path)
        XCTAssertEqual(normal.last, "cd -- " + SSHArguments.quote(path) + " && exec \"${SHELL:-/bin/sh}\" -l")
        let tmux = SSHArguments.terminal(profile, socket: "/tmp/socket", tmuxName: "session", workingDirectory: path)
        XCTAssertTrue(tmux.last!.contains(" -c " + SSHArguments.quote(path)))
        let original = SessionRecord(serverID: nil, serverName: "本机", title: "本机 · 1")
        let data = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(SessionRecord.self, from: data).workingDirectory)
    }
    func testBinaryTransportKeepsStderrSeparateAndDoesNotTruncate() async throws {
        let root = try temporary(), output = root.appendingPathComponent("binary")
        let data = Data((0..<300_000).map { UInt8($0 % 256) })
        try await FileProcess.run("/bin/sh", arguments: ["-c", "cat; printf diagnostic >&2"], input: data, output: output, timeout: 5)
        XCTAssertEqual(try Data(contentsOf: output), data)
    }
    func testPreviewRejectsOversizedFilesBeforeCopying() async throws {
        let root = try temporary(), cache = try temporary(), url = root.appendingPathComponent("huge.py")
        try Data(repeating: 97, count: 1024).write(to: url)
        let service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
        let entries = try await service.list(root.path)
        do { _ = try await service.materialize(entries.entries[0], limit: 10); XCTFail("Must refuse oversized preview") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }
    func testCancelledFileProcessStopsPromptly() async throws {
        let root = try temporary()
        let started = Date()
        let task = Task { try await FileProcess.run("/bin/sleep", arguments: ["30"], input: Data(), output: root.appendingPathComponent("output")) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { try await task.value; XCTFail("A cancelled directory request must stop its SSH channel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
    func testUnchangedDirectoryRefreshOmitsListingButStatsSelectedFile() async throws {
        let root = try temporary(), cache = try temporary()
        let file = root.appendingPathComponent("result.mp4")
        try Data("first".utf8).write(to: file)
        let service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
        let initial = try await service.list(root.path)
        let unchanged = try await service.refresh([.init(path: root.path, stamp: initial.stamp)], files: [file.path])
        XCTAssertNil(unchanged.directories.first?.listing)
        XCTAssertEqual(unchanged.files.first?.entry?.size, 5)
        try Data("more output".utf8).write(to: file)
        let altered = try await service.refresh([.init(path: root.path, stamp: initial.stamp)], files: [file.path])
        XCTAssertEqual(altered.files.first?.entry?.size, 11)
        try Data().write(to: root.appendingPathComponent("new-video.mp4"))
        let refreshed = try await service.refresh([.init(path: root.path, stamp: initial.stamp), .init(path: root.appendingPathComponent("missing").path)])
        XCTAssertEqual(refreshed.directories.first?.listing?.entries.count, 2)
        XCTAssertNotNil(refreshed.directories.last?.error)
    }
    func testTmuxFallbackAndArgumentsUseTheSameQuotedDirectory() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("中文 ' project")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let shell = root.appendingPathComponent("fake-shell")
        try "#!/bin/sh\nprintf 'FALLBACK_DIRECTORY=%s\\n' \"$PWD\"\n".write(to:shell,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shell.path)
        let command = try XCTUnwrap(SSHArguments.terminal(ServerProfile(name:"QA",host:"unused"),socket:"unused",tmuxName:"harbor-qa",workingDirectory:folder.path,directoryToken:"qa-token").last)
        let missing = await ProcessRunner.run("/bin/sh",["-c","PATH=/nonexistent; SHELL=" + SSHArguments.quote(shell.path) + "; export PATH SHELL; " + command])
        XCTAssertTrue(missing.succeeded)
        XCTAssertTrue(missing.output.contains("tmux is unavailable"))
        XCTAssertTrue(missing.output.contains("7778;qa-token;0"))
        XCTAssertTrue(missing.output.contains("7777;qa-token;"))
        XCTAssertTrue(missing.output.contains("FALLBACK_DIRECTORY=" + folder.path))
        let stub = root.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf 'ARG=%s\\n' \"$@\"\n".write(to:stub,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:stub.path)
        let present = await ProcessRunner.run("/bin/sh",["-c","PATH=" + SSHArguments.quote(root.path) + "; export PATH; " + command])
        XCTAssertTrue(present.succeeded)
        XCTAssertTrue(present.output.contains("ARG=-A")); XCTAssertTrue(present.output.contains("ARG=harbor-qa"))
        XCTAssertTrue(present.output.contains("ARG=" + folder.path))
        XCTAssertFalse(present.output.contains("FALLBACK_DIRECTORY="))
        XCTAssertTrue(present.output.contains("ARG=;\nARG=set-option\nARG=-t\nARG=harbor-qa\nARG=status\nARG=off"))
    }

}

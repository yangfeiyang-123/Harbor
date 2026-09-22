import XCTest
import HarborCore

final class WorkspaceOperationsTests: XCTestCase {
    func fixture() throws -> (URL, WorkspaceFileService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-file-operations-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, WorkspaceFileService(profile: nil, socket: nil, script: "", cache: root))
    }
    func testCopyMoveRenameKeepContentsAndRefuseOverwritingOrSelfDescendants() async throws {
        let (root, service) = try fixture()
        let folder = root.appendingPathComponent("文件夹 ' $(no)")
        let target = root.appendingPathComponent("target"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("代码\r\n".utf8).write(to: folder.appendingPathComponent("main.py"))
        let copy = try await service.operate("copy", path: folder.path, parent: root.path)
        XCTAssertNotEqual(copy, folder.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy).appendingPathComponent("main.py")), Data("代码\r\n".utf8))
        let moved = try await service.operate("move", path: copy, parent: target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
        let renamed = try await service.operate("rename", path: moved, parent: target.path, name: "new folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed))
        do { _ = try await service.operate("copy", path: folder.path, parent: folder.path); XCTFail("self copy must fail") } catch {}
        do { _ = try await service.operate("rename", path: folder.path, parent: root.path, name: "../escape"); XCTFail("invalid name") } catch {}
        do { _ = try await service.operate("move", path: folder.path, parent: target.path, name: "new folder"); XCTFail("must not overwrite") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    func testStreamedFolderTransferPreservesUnicodeBinaryPermissionsAndSafeSymlink() async throws {
        let (root, service) = try fixture()
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let nested = source.appendingPathComponent("中文 ' folder"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let data = Data((0..<2_500_000).map { UInt8($0 % 251) }), name = "视频.mp4"
        try data.write(to: nested.appendingPathComponent(name))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.appendingPathComponent(name).path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "中文 ' folder/" + name)
        let archive = try await service.exportItem(source.path)
        let result = try await service.importItem(archive, name: "copied", parent: target.path)
        let final = URL(fileURLWithPath: result)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("中文 ' folder/" + name)), data)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: final.appendingPathComponent("link").path), "中文 ' folder/" + name)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: final.appendingPathComponent("中文 ' folder/" + name).path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let second = try await service.importItem(archive, name: "copied", parent: target.path)
        XCTAssertNotEqual(result, second)
    }
    func testImportRejectsTraversalSymlinkParentAndTruncatedPayloadWithoutPublishing() async throws {
        let (root, service) = try fixture()
        func archive(_ records: [[String: Any]], tail: Data = Data()) throws -> URL {
            var result = Data()
            for record in records {
                let data = try JSONSerialization.data(withJSONObject: record); var length = UInt32(data.count).bigEndian
                withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }; result.append(data)
            }
            result.append(tail); result.append(Data(repeating: 0, count: 4))
            let url = root.appendingPathComponent(UUID().uuidString); try result.write(to: url); return url
        }
        let directory: [String: Any] = ["path": "item", "kind": "directory", "mode": 493]
        let malicious: [[[String: Any]]] = [
            [["path": "../escape", "kind": "directory", "mode": 493]],
            [directory, ["path": "item/link", "kind": "symlink", "mode": 493, "link": "../../escape"]],
            [directory, ["path": "item/file", "kind": "file", "mode": 420, "size": 100]],
            [directory, ["path": "item/link", "kind": "symlink", "mode": 493, "link": "."], ["path": "item/link/file", "kind": "file", "mode": 420, "size": 0]]
        ]
        for records in malicious {
            do { _ = try await service.importItem(archive(records), name: "must-not-exist", parent: root.path); XCTFail("accepted unsafe/incomplete archive") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".harbor-transfer-") })
        }
    }
    func testSwiftAndRemoteRuntimeTransferFormatsInteroperateBothWays() async throws {
        let (root, service) = try fixture()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/HarborSSH/Resources/WorkspaceRuntime/files.py")
        let source = root.appendingPathComponent("source"), uploads = root.appendingPathComponent("uploads")
        for folder in [source, uploads] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let bytes = Data((0..<1_300_000).map { UInt8($0 % 197) })
        try bytes.write(to: source.appendingPathComponent("视频 ' file.mp4"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "视频 ' file.mp4")
        func runtime(_ request: [String: String], input: URL? = nil, output: URL) throws {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let encoded = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
            task.arguments = [script.path, encoded]
            let read = try FileHandle(forReadingFrom: input ?? URL(fileURLWithPath: "/dev/null"))
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let write = try FileHandle(forWritingTo: output)
            defer { try? read.close(); try? write.close() }
            let errors = Pipe(); task.standardInput = read; task.standardOutput = write; task.standardError = errors
            try task.run(); task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let fromSwift = try await service.exportItem(source.path), response = root.appendingPathComponent("response.json")
        try runtime(["op": "import", "path": uploads.path, "name": "uploaded"], input: fromSwift, output: response)
        let uploaded = uploads.appendingPathComponent("uploaded")
        XCTAssertEqual(try Data(contentsOf: uploaded.appendingPathComponent("视频 ' file.mp4")), bytes)
        let fromPython = root.appendingPathComponent("python.transfer")
        try runtime(["op": "export", "path": uploaded.path], output: fromPython)
        let downloaded = try await service.importItem(fromPython, name: "downloaded", parent: root.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: downloaded).appendingPathComponent("link")), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: downloaded + "/link"), "视频 ' file.mp4")
    }
}

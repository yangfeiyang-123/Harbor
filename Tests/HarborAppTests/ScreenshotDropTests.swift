import XCTest
import AppKit
import UniformTypeIdentifiers
import HarborCore
@testable import HarborSSH

private final class ScreenshotPromise: NSFilePromiseReceiver {
    var names: [String] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail; super.init() }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { fail = false; super.init(pasteboardPropertyList: propertyList, ofType: type) }
    override var fileNames: [String] { names }
    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any], operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        names = ["Screenshot one.png", "Screenshot two.png"]
        for (index, name) in names.enumerated() {
            operationQueue.addOperation {
                let url = destinationDir.appendingPathComponent(name)
                if self.fail && index == 1 { reader(url, CocoaError(.fileWriteUnknown)); return }
                do { try Data([UInt8(index), 5, 9]).write(to: url); reader(url, nil) }
                catch { reader(url, error) }
            }
        }
    }
}

final class ScreenshotDropTests: XCTestCase {
    @MainActor func testScreenshotFileRepresentationSurvivesProviderCleanupAndUploadLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ephemeral.png"), bytes = Data([137, 80, 78, 71, 20, 44])
        try bytes.write(to: source)
        let provider = NSItemProvider(); provider.suggestedName = "Screenshot 2026-09-19 at 2.14.20 PM"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            try? FileManager.default.removeItem(at: source)
            return nil
        }
        let payload = WorkspaceDropPayload(providers: [provider], promises: [], nativeItems: [], image: nil, imageType: nil)
        var prepared: PreparedWorkspaceDrop? = try await payload.prepare()
        let entry = try XCTUnwrap(prepared?.items.first?.entry)
        XCTAssertTrue(entry.name.hasSuffix(".png")); XCTAssertNil(prepared?.items.first?.profileID)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.path)), bytes)
        let cache = root.appendingPathComponent("cache"), target = root.appendingPathComponent("selected folder")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
        let archive = try await service.exportItem(entry.path)
        let destination = try await service.importItem(archive, name: entry.name, parent: target.path)
        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes)
    }

    @MainActor func testNativePromisesReceiveEveryFileBeforeCleaningUp() async throws {
        let receiver = ScreenshotPromise()
        let payload = WorkspaceDropPayload(providers: [], promises: [receiver], nativeItems: [], image: nil, imageType: nil)
        var prepared: PreparedWorkspaceDrop? = try await payload.prepare()
        let items = try XCTUnwrap(prepared?.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.entry.name).sorted(), receiver.names)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: items[1].entry.path)), Data([1, 5, 9]))
        prepared = nil
        XCTAssertTrue(items.allSatisfy { !FileManager.default.fileExists(atPath: $0.entry.path) })
    }

    @MainActor func testFailedPromiseDoesNotReportSuccessOrLeakPartialFiles() async throws {
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("harbor-drop-") })
        let payload = WorkspaceDropPayload(providers: [], promises: [ScreenshotPromise(fail: true)], nativeItems: [], image: nil, imageType: nil)
        do { _ = try await payload.prepare(); XCTFail("failure must reach the user") } catch {}
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("harbor-drop-") })
        XCTAssertEqual(before, after)
    }

    @MainActor func testImagePasteboardAndDataOnlyProviderAreAccepted() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(png, forType: .png)
        let native = try await WorkspaceDropPayload.capture([], pasteboard: board).prepare()
        XCTAssertEqual(native.items.count, 1)
        let provider = NSItemProvider(); provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in completion(png, nil); return nil }
        let provided = try await WorkspaceDropPayload.capture([provider], pasteboard: board).prepare()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: provided.items[0].entry.path)), png)
    }
}

import XCTest
import HarborCore
@testable import HarborSSH

final class OptionalViewerTests: XCTestCase {
    @MainActor func testOptionalViewerIsSeparateFromThePublicBundleAndCannotServeOutsideItsRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-viewer-test-" + UUID().uuidString)
        let addon = root.appendingPathComponent("addon")
        try FileManager.default.createDirectory(at: addon, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let viewer = IsaacViewerServer(optionalViewerDirectory: addon)
        XCTAssertNotEqual(viewer.assetDirectory, addon)
        try Data("optional-viewer-fixture".utf8).write(to: addon.appendingPathComponent("index.html"))
        try Data("outside-private-file".utf8).write(to: root.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(at: addon.appendingPathComponent("escape.txt"), withDestinationURL: root.appendingPathComponent("private.txt"))
        XCTAssertEqual(viewer.assetDirectory, addon)
        try await viewer.start(); defer { viewer.stop() }
        let url = try XCTUnwrap(viewer.url(profile: RemoteDisplayProfile()))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "optional-viewer-fixture")
        let (_, denied) = try await URLSession.shared.data(from: url.appendingPathComponent("escape.txt"))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
    }
}

import XCTest
@testable import HarborCore

final class RemoteDisplayTests: XCTestCase {
    func testIsaacLaunchAndLegacyCatalogCompatibility() throws {
        var display = RemoteDisplayProfile(serverID: UUID())
        display.client = .isaac; display.preset = .isaac; display.address = "isaac://192.0.2.20:49100"; display.useSSHTunnel = false
        display.launch = SimulationLaunch(directory: "/home/user/Project with spaces")
        XCTAssertNil(display.validationError)
        XCTAssertEqual(display.port, 49100)
        let data = try JSONEncoder().encode(display)
        XCTAssertEqual(try JSONDecoder().decode(RemoteDisplayProfile.self, from: data), display)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "launch")
        let old = try JSONDecoder().decode(RemoteDisplayProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.launch)
        display.launch?.directory = "relative/path"; XCTAssertNotNil(display.validationError)
        display.launch?.directory = "/home/user"; display.useSSHTunnel = true; XCTAssertNotNil(display.validationError)
        display.useSSHTunnel = false; display.address = "http://host:49100"; XCTAssertNotNil(display.validationError)
    }
    func testTunnelRewritesOnlyOriginAndBindsOnlyLoopback() throws {
        var display = RemoteDisplayProfile(serverID: UUID())
        display.address = "http://localhost:6080/prefix/vnc.html?path=prefix%2Fwebsockify&resize=remote#connect"
        XCTAssertNil(display.validationError)
        let url = try XCTUnwrap(display.localURL(port: 43210))
        XCTAssertEqual(url.host, "127.0.0.1"); XCTAssertEqual(url.port, 43210)
        XCTAssertEqual(url.path, "/prefix/vnc.html"); XCTAssertEqual(url.query, display.url?.query); XCTAssertEqual(url.fragment, "connect")
        let server = ServerProfile(name: "QA", host: "test-alias", imported: true)
        let args = display.tunnelArguments(server: server, localPort: 43210)
        XCTAssertTrue(args.contains("127.0.0.1:43210:localhost:6080"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes")); XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "test-alias"])
        XCTAssertFalse(args.contains("-R")); XCTAssertFalse(args.contains("-g"))
    }
    func testValidationSeparatesViewerProtocolsAndPreservesTLSChecks() {
        var display = RemoteDisplayProfile(serverID: UUID())
        for address in ["file:///etc/passwd", "javascript:alert(1)", "http://name:password@host:80/", "http://localhost:70000/"] {
            display.address = address; XCTAssertNotNil(display.validationError, address)
        }
        display.address = "https://viewer.example.org/"
        XCTAssertNotNil(display.validationError)
        display.useSSHTunnel = false; XCTAssertNil(display.validationError)
        display.preset = .isaac; XCTAssertNotNil(display.validationError)
        display.client = .chromium; XCTAssertNil(display.validationError)
        display.client = .vnc; XCTAssertNotNil(display.validationError)
        display.address = "vnc://127.0.0.1:5901"; display.useSSHTunnel = true; XCTAssertNil(display.validationError)
        XCTAssertEqual(display.port, 5901)
        display.serverID = nil; XCTAssertNotNil(display.validationError)
        display.useSSHTunnel = false; XCTAssertNil(display.validationError)
    }
    func testPrivatePersistenceAndServerIdentityRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("displays.json")
        var first = RemoteDisplayProfile(serverID: UUID()); first.name = "A6000 · Robot"
        var second = first; second.id = UUID(); second.serverID = UUID(); second.client = .vnc
        try RemoteDisplayPersistence.save([first, second], to: file)
        XCTAssertEqual(try RemoteDisplayPersistence.load(file), [first, second])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

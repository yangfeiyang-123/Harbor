import XCTest
@testable import HarborCore

private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileProcessProgress] = []
    func add(_ value: FileProcessProgress) { lock.lock(); values.append(value); lock.unlock() }
    var all: [FileProcessProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

final class FileTransferProgressTests: XCTestCase {
    func testUploadAndDownloadReportLiveByteCountsWithoutBufferingPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-byte-progress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source"), output = root.appendingPathComponent("target")
        let data = Data(repeating: 71, count: 800_000); try data.write(to: input)
        let samples = Samples()
        let script = "import sys,time\nwhile True:\n b=sys.stdin.buffer.read(32768)\n if not b: break\n sys.stdout.buffer.write(b);sys.stdout.buffer.flush();time.sleep(.035)"
        try await FileProcess.run("/usr/bin/python3", arguments: ["-c", script], input: Data(), output: output, timeout: 15, inputFile: input, progress: { samples.add($0) })
        let values = samples.all
        XCTAssertGreaterThan(values.count, 3)
        XCTAssertEqual(values.last?.inputBytes, Int64(data.count)); XCTAssertEqual(values.last?.outputBytes, Int64(data.count))
        XCTAssertTrue(values.contains { $0.outputBytes > 0 && $0.outputBytes < data.count })
        for (a, b) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(a.inputBytes, b.inputBytes); XCTAssertLessThanOrEqual(a.outputBytes, b.outputBytes) }
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    func testFailedTransportKeepsPartialCountAndThrows() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let samples = Samples()
        do {
            try await FileProcess.run("/bin/sh", arguments: ["-c", "printf partial; exit 7"], input: Data(), output: output, timeout: 5, progress: { samples.add($0) })
            XCTFail("a failed transfer must not be reported as complete")
        } catch { XCTAssertEqual(samples.all.last?.outputBytes, 7) }
    }
}

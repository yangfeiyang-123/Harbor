import XCTest
import Darwin
@testable import HarborCore

final class ProcessRunnerTests: XCTestCase {
    func testConcurrentShortLivedProcessesKeepTheirOwnOutputAndExitStatus() async {
        // Repeated quick exits used to race queued FileHandle callbacks against close.
        let failures = await withTaskGroup(of: [String].self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var failures: [String] = []
                    for iteration in 0..<40 {
                        let marker = "\(worker)-\(iteration)-连接✓"
                        let status = Int32(iteration % 8)
                        let result = await ProcessRunner.run("/bin/sh", ["-c", "printf '%s' '\(marker)'; printf ':stderr:end' >&2; exit \(status)"], timeout: 5)
                        if result.timedOut || result.status != status || result.output != marker + ":stderr:end" {
                            failures.append("\(marker): status=\(result.status), timeout=\(result.timedOut), output=\(result.output)")
                        }
                    }
                    return failures
                }
            }
            var failures: [String] = []
            for await batch in group { failures += batch }
            return failures
        }
        XCTAssertEqual(failures, [])
    }

    func testOutputBeyondRetentionLimitIsStillDrainedToCompletion() {
        let result = ProcessRunner.sync("/bin/sh", ["-c", "/usr/bin/head -c 6000000 /dev/zero; printf END >&2; exit 9"], timeout: 10)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 9)
        XCTAssertEqual(result.output.utf8.count, 4_000_000)
        XCTAssertTrue(result.output.utf8.allSatisfy { $0 == 0 })
    }

    func testTimeoutKeepsDrainingTerminationHandlerOutput() {
        let result = ProcessRunner.sync("/bin/sh", ["-c", "trap '/usr/bin/head -c 200000 /dev/zero; printf TERMINATED; exit 23' TERM; printf READY; while :; do :; done"], timeout: 0.25)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 23)
        XCTAssertTrue(result.output.hasPrefix("READY"))
        XCTAssertTrue(result.output.hasSuffix("TERMINATED"))
        XCTAssertEqual(result.output.utf8.count, 200_015)
    }

    func testNoisyChildCannotStarveTimeoutAndKill() {
        let start = Date()
        let result = ProcessRunner.sync("/bin/sh", ["-c", "trap '' TERM; exec /usr/bin/yes noise"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertEqual(result.output.utf8.count, 4_000_000)
    }

    func testEOFDoesNotSkipTheProcessExitOrTimeout() {
        let result = ProcessRunner.sync("/bin/sh", ["-c", "printf BEFORE_EOF; exec 1>&- 2>&-; trap '' TERM; exec /bin/sleep 10"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertEqual(result.output, "BEFORE_EOF")
        let exited = ProcessRunner.sync("/bin/sh", ["-c", "exec 1>&- 2>&-; /bin/sleep 0.1; exit 6"])
        XCTAssertFalse(exited.timedOut)
        XCTAssertEqual(exited.status, 6)
    }

    func testExitDoesNotWaitForBackgroundChildToCloseInheritedPipe() throws {
        let start = Date()
        let result = ProcessRunner.sync("/bin/sh", ["-c", "/bin/sleep 10 & printf '%s\n' $!; printf PARENT_EXIT; exit 4"], timeout: 2)
        let pid = try XCTUnwrap(Int32(result.output.split(separator: "\n").first ?? ""))
        defer { kill(pid, SIGKILL) }
        XCTAssertEqual(result.status, 4)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.hasSuffix("PARENT_EXIT"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(kill(pid, 0), 0, "The intentional background process should survive its parent.")
    }

    func testRepeatedFailuresAndExitsReleasePipeDescriptors() {
        func descriptors() -> Set<Int32> {
            Set((0..<512).map(Int32.init).filter { fcntl($0, F_GETFD) != -1 })
        }
        // Warm up Foundation's process-monitor descriptors before taking a baseline.
        _ = ProcessRunner.sync("/usr/bin/true", [])
        _ = ProcessRunner.sync("/no/such/harbor-test-executable", [])
        let before = descriptors()
        for _ in 0..<40 {
            XCTAssertTrue(ProcessRunner.sync("/usr/bin/true", []).succeeded)
            let result = ProcessRunner.sync("/no/such/harbor-test-executable", [])
            XCTAssertEqual(result.status, -1)
            XCTAssertFalse(result.timedOut)
        }
        XCTAssertEqual(descriptors(), before)
    }
}

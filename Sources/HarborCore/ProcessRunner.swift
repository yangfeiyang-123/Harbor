import Foundation
import Darwin

public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var timedOut: Bool
    public var succeeded: Bool { status == 0 && !timedOut }
    public init(status: Int32, output: String, timedOut: Bool) {
        self.status = status; self.output = output; self.timedOut = timedOut
    }
}

public enum ProcessRunner {
    /// `environment` is added to this process's own for the command.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15, environment: [String: String]? = nil) async -> CommandResult {
        await Task.detached(priority: .utility) { sync(executable, arguments, timeout: timeout, environment: environment) }.value
    }
    public static func sync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15, environment: [String: String]? = nil) -> CommandResult {
        let process = Process(), pipe = Pipe()
        let reader = pipe.fileHandleForReading, writer = pipe.fileHandleForWriting
        defer { try? reader.close(); try? writer.close() }
        let fd = reader.fileDescriptor
        // This thread owns every read and the close. Removing a FileHandle readability
        // handler does not join callbacks already in flight; availableData can then
        // raise an Objective-C exception on the closed/nonblocking descriptor.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return CommandResult(status: -1, output: String(cString: strerror(errno)), timedOut: false)
        }
        // Unrelated terminals may launch while a connection check is running.
        for descriptor in [fd, writer.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
        var output = Data()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch {
            return CommandResult(status: -1, output: error.localizedDescription, timedOut: false)
        }
        // Only the child needs the writer. Its exit can now produce EOF immediately.
        try? writer.close()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        func drain() -> Bool {
            // Bound each pass so a noisy child cannot starve timeout/exit checks.
            for _ in 0..<32 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    if output.count < 4_000_000 {
                        output.append(contentsOf: bytes.prefix(min(count, 4_000_000 - output.count)))
                    }
                    continue // Keep draining even after the retained-output limit.
                }
                if count < 0, errno == EINTR { continue }
                return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
            }
            return true
        }
        var readable = true
        func waitForExit(until deadline: DispatchTime) -> Bool {
            while true {
                if readable { readable = drain() }
                if completed.wait(timeout: .now()) == .success { return true }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { return false }
                let milliseconds = Int32(min(50, (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000))
                if readable {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    _ = poll(&descriptor, 1, milliseconds)
                } else if completed.wait(timeout: .now() + .milliseconds(Int(milliseconds))) == .success {
                    return true // EOF need not mean the process has exited yet.
                }
            }
        }
        let deadline: DispatchTime = timeout == .infinity ? .distantFuture : .now() + (timeout.isFinite ? max(0, timeout) : 0)
        let timedOut = !waitForExit(until: deadline)
        if timedOut {
            if process.isRunning { process.terminate() }
            if !waitForExit(until: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = waitForExit(until: .now() + 2)
            }
        }
        // Capture the exit tail, but never wait for EOF held by a background child
        // (for example an SSH control master that intentionally stays alive).
        if readable { _ = drain() }
        return CommandResult(status: process.isRunning ? -1 : process.terminationStatus,
                             output: String(decoding: output, as: UTF8.self), timedOut: timedOut)
    }
}

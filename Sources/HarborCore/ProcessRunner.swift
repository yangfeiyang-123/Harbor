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
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) async -> CommandResult {
        await Task.detached(priority: .utility) { sync(executable, arguments, timeout: timeout) }.value
    }
    public static func sync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) -> CommandResult {
        let process = Process(), pipe = Pipe(), lock = NSLock()
        var output = Data()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock(); if output.count < 4_000_000 { output.append(data.prefix(4_000_000 - output.count)) }; lock.unlock()
        }
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: -1, output: error.localizedDescription, timedOut: false)
        }
        let timedOut = completed.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = completed.wait(timeout: .now() + 2) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // Close the parent's writer before draining. Never wait for EOF from an orphaned subprocess.
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &bytes, bytes.count); if n <= 0 { break }
            lock.lock(); if output.count < 4_000_000 { output.append(contentsOf: bytes.prefix(min(n, 4_000_000 - output.count))) }; lock.unlock()
        }
        try? pipe.fileHandleForReading.close()
        lock.lock(); let text = String(decoding: output, as: UTF8.self); lock.unlock()
        return CommandResult(status: process.isRunning ? -1 : process.terminationStatus, output: text, timedOut: timedOut)
    }
}

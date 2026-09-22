import Foundation
import Darwin

/// A tiny child mode of the signed app: one local PTY, an SSH pipe, and the
/// existing remote PTY. SSH gets no login tty for syslog/wall to write into.
/// Size frames travel separately from user input, including unchanged-size redraws.
enum TerminalTransport {
    nonisolated(unsafe) private static var resized = true
    nonisolated(unsafe) private static var stopping = false

    static var executable: String {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["HARBOR_QA_TRANSPORT_EXECUTABLE"] { return path }
        #endif
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static func packet(_ kind: UInt8, _ data: Data) -> Data {
        var size = UInt32(data.count).bigEndian
        var result = Data([kind])
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(data); return result
    }

    static func run(arguments: [String], token: String) throws -> Int32 {
        signal(SIGWINCH) { _ in TerminalTransport.resized = true }
        signal(SIGTERM) { _ in TerminalTransport.stopping = true }
        signal(SIGHUP) { _ in TerminalTransport.stopping = true }
        signal(SIGPIPE, SIG_IGN)
        let ssh = Process(), input = Pipe(), output = Pipe()
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); ssh.arguments = arguments
        ssh.standardInput = input; ssh.standardOutput = output; ssh.standardError = FileHandle.standardError
        try ssh.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        let writeFD = input.fileHandleForWriting.fileDescriptor, readFD = output.fileHandleForReading.fileDescriptor
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let stdinFlags = fcntl(STDIN_FILENO, F_GETFL)
        var original = termios()
        let hasTTY = tcgetattr(STDIN_FILENO, &original) == 0
        var ready = false, outputIsRaw = false, tail = Data(), pending = Data(), offset = 0
        let marker = Data(("\u{1b}]7777;" + token + ";").utf8)
        defer {
            if outputIsRaw, hasTTY { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
            if ready { _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags) }
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if ssh.isRunning { ssh.terminate() }
        }
        func append(_ kind: UInt8, _ data: Data) { pending.append(packet(kind, data)) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !stopping {
            if ready && resized {
                resized = false
                var size = winsize()
                if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 {
                    append(82, Data("[\(max(2, size.ws_row)),\(max(2, size.ws_col))]".utf8))
                }
            }
            var watches = [pollfd(fd: readFD, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: ready && pending.count - offset < 1_048_576 ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: offset < pending.count ? writeFD : -1, events: Int16(POLLOUT), revents: 0)]
            let status = poll(&watches, nfds_t(watches.count), 100)
            if status < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if watches[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count <= 0 { break }
                let data = Data(buffer.prefix(count))
                // Replayed terminal output can precede the handshake marker.
                // Preserve its line endings from the very first byte, while
                // leaving canonical input available for SSH authentication.
                if !outputIsRaw, hasTTY {
                    var rawOutput = original; rawOutput.c_oflag &= ~tcflag_t(OPOST)
                    _ = tcsetattr(STDIN_FILENO, TCSANOW, &rawOutput); outputIsRaw = true
                }
                try FileHandle.standardOutput.write(contentsOf: data)
                if !ready {
                    tail.append(data)
                    if tail.range(of: marker) != nil {
                        ready = true; resized = true
                        if hasTTY { var raw = original; cfmakeraw(&raw); _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw) }
                        _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK)
                    }
                    tail = Data(tail.suffix(marker.count))
                }
            }
            if watches[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count > 0 { append(73, Data(buffer.prefix(count))) }
            }
            if watches[2].revents & Int16(POLLERR | POLLHUP) != 0 { break }
            if watches[2].revents & Int16(POLLOUT) != 0, offset < pending.count {
                let count = pending.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress! + offset, pending.count - offset) }
                if count > 0 {
                    offset += count
                    if offset == pending.count { pending.removeAll(keepingCapacity: true); offset = 0 }
                    else if offset > 65_536 { pending.removeFirst(offset); offset = 0 }
                } else if errno != EAGAIN && errno != EINTR { break }
            }
        }
        if !stopping {
            let deadline = Date().addingTimeInterval(2)
            while ssh.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        return ssh.isRunning ? 1 : ssh.terminationStatus
    }
}

@main
enum HarborMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 4, arguments[1] == "--terminal-transport" {
            do { exit(try TerminalTransport.run(arguments: Array(arguments.dropFirst(3)), token: arguments[2])) }
            catch {
                try? FileHandle.standardError.write(contentsOf: Data(("Harbor: " + error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        HarborApp.main()
    }
}

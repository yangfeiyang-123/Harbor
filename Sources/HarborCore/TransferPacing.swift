import Foundation
import Darwin

/// Tokens for bulk bytes Harbor sends to a server behind the managed reverse tunnel.
///
/// The tunnel's gateway paces proxied traffic to what the VPN path carries, but Harbor's
/// file transfers ride its own ssh connection and bypassed it: one 500 MB upload filled the
/// VPN's queue, the path's round trip went to 21 s, and Codex on the server timed out for
/// half an hour. An upload now takes tokens from the same bucket (`serve_tokens` in
/// gateway-shaper.py) before every slice, so it is one more connection in that scheduler
/// and the rate controller sees its bytes. Downloads do the same on the server (files.py).
/// While the gateway does not answer, slices go out at a conservative fixed rate: the path
/// is already in trouble then, and full speed is what caused the incident.
public final class TransferPacer: @unchecked Sendable {
    public static let fallbackRate = 32 * 1024
    private let port: Int, fallbackRate: Double, answerTimeout: Int, retryDelay: Double, silentDelay: Double
    private let lock = NSLock()
    private var descriptor: Int32 = -1, cancelled = false
    private var ready = 0.0, retryAt = 0.0

    /// A paused pacer still grants a slice every eight seconds, so `answerTimeout` of silence means the
    /// gateway is wedged. It is then left alone for `silentDelay`: reconnecting at once would wait out
    /// another timeout per slice and turn the fallback rate into a few bytes per second.
    public init(port: Int, fallbackRate: Int = TransferPacer.fallbackRate, answerTimeout: Int = 45, retryDelay: TimeInterval = 30, silentDelay: TimeInterval = 300) {
        self.port = port; self.fallbackRate = Double(max(1, fallbackRate))
        self.answerTimeout = max(1, answerTimeout); self.retryDelay = retryDelay; self.silentDelay = silentDelay
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Blocks until part of `count` bytes may be sent and returns how many; 0 after `cancel()`.
    /// Called from one writer at a time.
    public func take(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        if cancelled { lock.unlock(); return 0 }
        var fd = descriptor
        lock.unlock()
        if fd < 0, Self.now >= retryAt {
            // Not under the lock: a wedged listener can hold connect for a long time, and cancel() must not wait for it.
            let opened = open()
            lock.lock()
            if cancelled { if opened >= 0 { Darwin.close(opened) }; lock.unlock(); return 0 }
            descriptor = opened; fd = opened
            lock.unlock()
            if opened < 0 { retryAt = Self.now + retryDelay }
        }
        if fd >= 0 {
            let (granted, silent) = request(count, on: fd)
            if let granted, granted > 0, granted <= count { return granted }
            lock.lock()
            if descriptor == fd { Darwin.close(fd); descriptor = -1 }
            let stop = cancelled
            lock.unlock()
            if stop { return 0 }
            retryAt = Self.now + (silent ? silentDelay : retryDelay)
        }
        let granted = min(count, max(1, Int(fallbackRate / 10)))
        let wait = ready - Self.now
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        ready = max(Self.now, ready) + Double(granted) / fallbackRate
        lock.lock(); let stop = cancelled; lock.unlock()
        return stop ? 0 : granted
    }

    /// Wakes a blocked `take` and makes every later one return 0.
    public func cancel() {
        lock.lock(); cancelled = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    /// A connected descriptor that has said hello, or -1.
    private func open() -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var receive = timeval(tv_sec: answerTimeout, tv_usec: 0), send = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(clamping: port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected, Self.write("RP-TAKE\n", to: fd) else { Darwin.close(fd); return -1 }
        return fd
    }

    private static func write(_ text: String, to fd: Int32) -> Bool {
        var bytes = Array(text.utf8)
        while !bytes.isEmpty {
            let sent = Darwin.send(fd, bytes, bytes.count, 0)
            if sent <= 0 { if sent < 0, errno == EINTR { continue }; return false }
            bytes.removeFirst(sent)
        }
        return true
    }

    /// The grant, and whether the gateway stayed silent for the whole answer timeout.
    private func request(_ count: Int, on fd: Int32) -> (Int?, silent: Bool) {
        guard Self.write("\(min(count, 1 << 20))\n", to: fd) else { return (nil, false) }
        var line = [UInt8](), byte: UInt8 = 0
        while line.count <= 20 {
            let got = recv(fd, &byte, 1, 0)
            if got < 0, errno == EINTR { continue }
            guard got == 1 else { return (nil, got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) }
            if byte == UInt8(ascii: "\n") { return (Int(String(decoding: line, as: UTF8.self)), false) }
            line.append(byte)
        }
        return (nil, false)
    }
}

/// Resolves the gateway relay port for the server a file service talks to; nil when the
/// server is not behind the managed tunnel or the gateway is not running. Asked at the start
/// of every bulk transfer, because the tunnel may come up long after the workspace opened.
public typealias TransferRelayLookup = @Sendable () async -> Int?

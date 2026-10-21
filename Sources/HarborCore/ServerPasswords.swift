import Foundation
import Darwin
import CryptoKit

/// A server's SSH password, asked for once.
///
/// Harbor's terminals run OpenSSH with Harbor itself as its askpass program (`SSH_ASKPASS`,
/// forced), so every question ssh would put to the terminal comes here first. A password question
/// is answered from the login keychain when one is kept for that server and account. Every other
/// question (a new host key, a key's passphrase, a one-time code), and a password not kept yet, is
/// asked in the terminal as ssh itself asks it. A password typed there is kept at once, and given
/// without asking only after a connection with it has been made (`confirm`): one that ssh asks for
/// again in the same connection was refused, and is dropped and asked for again.
///
/// The keychain is reached through `/usr/bin/security`. What it adds it reads again without a
/// dialog; an item added by Harbor's own executable, which is signed anew by every build, would ask
/// for the login password after each one. As with an SSH key without a passphrase, a program run as
/// this user can read a kept password; it is encrypted on disk with the login keychain.
public enum ServerPasswords {
    /// Set for ssh by Harbor: the server's id, a space, and an id of this connection; then
    /// " background" when there is no terminal to ask in (a connection Harbor makes for the editor
    /// and the file browser, with a password kept or typed in Harbor's dialog).
    public static let variable = "HARBOR_ASKPASS"

    public static func environment(server: UUID, executable: String, connection: String = UUID().uuidString, background: Bool = false) -> [String: String] {
        ["SSH_ASKPASS": executable, "SSH_ASKPASS_REQUIRE": "force",
         variable: server.uuidString + " " + connection + (background ? " background" : "")]
    }

    public static func service(_ server: UUID) -> String { "Harbor SSH " + server.uuidString }

    /// Whom ssh asks a password for, `user@host`, read from its question; nil for any other
    /// question. Password authentication asks "user@host's password: "; keyboard-interactive puts
    /// "(user@host) " (OpenSSH 8.2 and later) before the server's "Password: ".
    public static func account(asked prompt: String) -> String? {
        var account: Substring?
        let password = "'s password: "
        if prompt.hasSuffix(password) { account = prompt.dropLast(password.count) }
        else if prompt.hasPrefix("(") {
            for ending in [") Password: ", ") Password:"] where prompt.hasSuffix(ending) {
                account = prompt.dropFirst().dropLast(ending.count); break
            }
        }
        guard let account, account.contains("@"), account.count <= 512,
              !account.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        return String(account)
    }

    /// Whom ssh was refused for, when the server would have taken a password: from its last words,
    /// "user@host: Permission denied (publickey,password)." nil for any other failure, and for a
    /// server that takes keys only.
    public static func account(refused message: String) -> String? {
        for line in message.split(whereSeparator: { $0.isNewline }).reversed() {
            guard let range = line.range(of: ": Permission denied (") else { continue }
            let methods = line[range.upperBound...]
            guard methods.contains("password") || methods.contains("keyboard-interactive") else { return nil }
            let account = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return account.contains("@") && !account.contains(" ") ? account : nil
        }
        return nil
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The note that a password was typed for a connection not yet known to have been made.
    static func markerName(_ server: UUID, _ account: String) -> String {
        "unconfirmed-" + server.uuidString + "-" + digest(account)
    }

    /// A password is kept for the account, and a connection has been made with it.
    public static func usable(server: UUID, account: String, keeper: any PasswordKeeper = KeychainTool(), directory: URL? = nil) -> Bool {
        guard let directory = directory ?? stateDirectory(),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerName(server, account)).path) else { return false }
        return keeper.password(service: service(server), account: account) != nil
    }

    /// A password typed in Harbor's dialog: kept, and given by the askpass program in `connection`
    /// only, until that connection is made (`confirm`), as one typed in a terminal is.
    @discardableResult
    public static func offer(_ password: String, server: UUID, account: String, connection: String,
                             keeper: any PasswordKeeper = KeychainTool(), directory: URL? = nil) -> Bool {
        guard !password.isEmpty, let directory = directory ?? stateDirectory(),
              keeper.keep(password, service: service(server), account: account, label: "Harbor SSH · " + account) else { return false }
        try? Data(connection.utf8).write(to: directory.appendingPathComponent(markerName(server, account)), options: .atomic)
        return true
    }

    /// A password the server refused is removed.
    public static func drop(server: UUID, account: String, keeper: any PasswordKeeper = KeychainTool(), directory: URL? = nil) {
        keeper.remove(service: service(server), account: account)
        if let directory = directory ?? stateDirectory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(markerName(server, account)))
        }
    }

    /// Where the askpass program notes what it has answered: nothing secret, and only for this
    /// user (the directory Harbor's file connections use).
    public static func stateDirectory() -> URL? {
        let root = "/tmp/harbor-\(getuid())"
        for path in [root, root + "/askpass"] {
            var info = stat()
            if lstat(path, &info) != 0 {
                if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
                guard lstat(path, &info) == 0 else { return nil }
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        }
        return URL(fileURLWithPath: root + "/askpass", isDirectory: true)
    }

    /// A connection to the server has been made: a password typed for it is right, and is given
    /// from now on without asking.
    public static func confirm(server: UUID, directory: URL? = nil) {
        guard let directory = directory ?? stateDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("unconfirmed-" + server.uuidString + "-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Every password kept for the server is removed. True when there was one.
    @discardableResult
    public static func forget(server: UUID, keeper: any PasswordKeeper = KeychainTool(), directory: URL? = nil) -> Bool {
        confirm(server: server, directory: directory)
        return keeper.remove(service: service(server), account: nil)
    }

    public static func kept(server: UUID, keeper: any PasswordKeeper = KeychainTool()) -> Bool {
        keeper.contains(service: service(server))
    }

    /// An ssh that asks nothing (`BatchMode=yes`), for a server that takes a password Harbor keeps:
    /// the same ssh, answered by Harbor's askpass program instead, with no terminal (one password,
    /// the kept one, and nothing asked), and the environment that makes it so. Unchanged, with no
    /// environment, for a server without a kept password: keys work as they did.
    public static func quiet(_ arguments: [String], server: UUID, executable: String,
                             keeper: any PasswordKeeper = KeychainTool()) -> (arguments: [String], environment: [String: String]?) {
        guard let batch = arguments.firstIndex(of: "BatchMode=yes"), kept(server: server, keeper: keeper) else { return (arguments, nil) }
        var result = arguments
        result[batch] = "BatchMode=no"
        result.insert(contentsOf: ["-o", "NumberOfPasswordPrompts=1"], at: batch + 1)
        return (result, environment(server: server, executable: executable, background: true))
    }

    /// Harbor run by ssh as its askpass program: the question is the one argument, the answer is
    /// written to standard output. Returns the exit status; not 0 when no answer was given.
    public static func askpass(question: String, value: String) -> Int32 {
        let parts = value.split(separator: " ").map(String.init)
        let background = parts.count > 2 && parts[2] == "background"
        let answer: String?
        if parts.count >= 2, let server = UUID(uuidString: parts[0]), let directory = stateDirectory() {
            cleanUp(directory)
            answer = Askpass(server: server, connection: parts[1], keeper: KeychainTool(), directory: directory, background: background,
                             ask: { ServerPasswords.askInTerminal($0, echo: $1) }, note: { ServerPasswords.tellInTerminal($0) }).answer(question)
        } else {
            answer = background ? nil : askInTerminal(question, echo: question.contains("(yes/no"))
        }
        guard let answer else {
            // No one to ask: ssh would send an empty password, which the server counts as a failed
            // attempt (and a host key would be refused anyway). It is stopped instead.
            if background { kill(getppid(), SIGTERM) }
            return 1
        }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }

    /// What was noted for connections more than two days ago is of no more use.
    static func cleanUp(_ directory: URL) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { return }
        let old = Date().addingTimeInterval(-2 * 86_400)
        for name in names where name.hasPrefix("run-") {
            let url = directory.appendingPathComponent(name)
            if let date = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, date < old {
                try? files.removeItem(at: url)
            }
        }
    }

    nonisolated(unsafe) private static var restoring: Int32 = -1
    nonisolated(unsafe) private static var restoreState = termios()

    private static func show(_ text: String, on descriptor: Int32) {
        let shown = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let bytes = Array(shown.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue } else { return }
        }
    }

    static func tellInTerminal(_ text: String) {
        let descriptor = open("/dev/tty", O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        show("\u{1b}[2m" + text + "\u{1b}[0m\n", on: descriptor)
    }

    /// The question in the terminal ssh runs in, as ssh asks it: the answer is not shown while it
    /// is typed, unless `echo`. nil when there is no terminal, or it was closed before Return.
    static func askInTerminal(_ prompt: String, echo: Bool) -> String? {
        let descriptor = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var original = termios()
        let terminal = tcgetattr(descriptor, &original) == 0
        let quiet = !echo && terminal
        if quiet {
            restoreState = original; restoring = descriptor
            for kind in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP] {
                signal(kind) { number in
                    if ServerPasswords.restoring >= 0 { _ = tcsetattr(ServerPasswords.restoring, TCSAFLUSH, &ServerPasswords.restoreState) }
                    _exit(128 + number)
                }
            }
            var silent = original
            silent.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHONL)
            _ = tcsetattr(descriptor, TCSAFLUSH, &silent)
        }
        show(prompt, on: descriptor)
        var bytes = [UInt8](), byte: UInt8 = 0, ended = false
        while bytes.count < 8_192 {
            let count = read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 10 || byte == 13 { ended = true; break }
                bytes.append(byte); continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        if quiet {
            _ = tcsetattr(descriptor, TCSAFLUSH, &original); restoring = -1
            show("\n", on: descriptor)
        } else { show("\r", on: descriptor) }
        guard ended || !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Where passwords are kept: the login keychain, or a stand-in in tests.
public protocol PasswordKeeper {
    func password(service: String, account: String) -> String?
    @discardableResult func keep(_ password: String, service: String, account: String, label: String) -> Bool
    /// Removes the account's item, or every item of the service when `account` is nil. True when one was removed.
    @discardableResult func remove(service: String, account: String?) -> Bool
    func contains(service: String) -> Bool
}

/// The login keychain, through `/usr/bin/security`. The password is kept as base64 of its UTF-8:
/// `security … -w` prints a password with bytes outside printable ASCII in hex, which could not be
/// told from a password that is hex.
public struct KeychainTool: PasswordKeeper {
    public var path: String
    public init(path: String = "/usr/bin/security") { self.path = path }

    func run(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    public func password(service: String, account: String) -> String? {
        let result = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard result.status == 0,
              let text = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func keep(_ password: String, service: String, account: String, label: String) -> Bool {
        run(["add-generic-password", "-U", "-s", service, "-a", account, "-l", label,
             "-w", Data(password.utf8).base64EncodedString()]).status == 0
    }

    @discardableResult
    public func remove(service: String, account: String?) -> Bool {
        var removed = false
        for _ in 0..<64 {
            guard run(["delete-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? [])).status == 0 else { break }
            removed = true
        }
        return removed
    }

    public func contains(service: String) -> Bool { run(["find-generic-password", "-s", service]).status == 0 }
}

/// One question from ssh, for one server and one connection.
public struct Askpass {
    public var server: UUID
    public var connection: String
    public var keeper: any PasswordKeeper
    public var directory: URL
    /// No terminal: only a kept password is given, nothing is asked.
    public var background: Bool
    /// Asks in the terminal: the question, and whether the answer is shown as it is typed.
    public var ask: (String, Bool) -> String?
    public var note: (String) -> Void

    public init(server: UUID, connection: String, keeper: any PasswordKeeper, directory: URL, background: Bool = false,
                ask: @escaping (String, Bool) -> String?, note: @escaping (String) -> Void) {
        self.server = server; self.connection = connection; self.keeper = keeper; self.directory = directory
        self.background = background; self.ask = ask; self.note = note
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func write(_ value: String, to url: URL) { try? Data(value.utf8).write(to: url, options: .atomic) }

    public func answer(_ prompt: String) -> String? {
        guard let account = ServerPasswords.account(asked: prompt) else {
            // A new host key and the like: asked as ssh asks, a yes or no shown as it is typed.
            return background ? nil : ask(prompt, prompt.contains("(yes/no"))
        }
        let service = ServerPasswords.service(server)
        let run = directory.appendingPathComponent("run-" + ServerPasswords.digest(connection + "\n" + account))
        let marker = directory.appendingPathComponent(ServerPasswords.markerName(server, account))
        if text(run) == nil {
            if let typedFor = text(marker), typedFor != connection {
                // Typed for a connection that was never made: not known to be right, so not given.
                keeper.remove(service: service, account: account); try? FileManager.default.removeItem(at: marker)
            } else if let kept = keeper.password(service: service, account: account) {
                write("kept", to: run); return kept
            }
        } else {
            // ssh asks again in the same connection: the server refused the last answer.
            keeper.remove(service: service, account: account); try? FileManager.default.removeItem(at: marker)
        }
        guard !background else { return nil }
        note("Harbor remembers this password in your login keychain.")
        guard let typed = ask(prompt, false) else { return nil }
        write("typed", to: run)
        if !typed.isEmpty, keeper.keep(typed, service: service, account: account, label: "Harbor SSH · " + account) {
            write(connection, to: marker)
        }
        return typed
    }
}

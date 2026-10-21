import Foundation
import CryptoKit
import Darwin

/// Terminals can exhaust sshd's per-connection MaxSessions while SSH itself is
/// still healthy. File operations then use their own short-lived control master.
/// Retry only refusals that happened before the remote command could start.
public final class WorkspaceSSHConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var useFileConnection = false
    public let profile: ServerProfile
    public let sharedSocket: String
    public let fileSocket: String

    public init(profile: ServerProfile, socket: String) {
        self.profile = profile; sharedSocket = socket
        let key = SHA256.hash(data: Data((socket + "|" + profile.host).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        fileSocket = "/tmp/harbor-\(getuid())/files-" + key
    }
    private var prefersFiles: Bool {
        get { lock.lock(); defer { lock.unlock() }; return useFileConnection }
        set { lock.lock(); useFileConnection = newValue; lock.unlock() }
    }
    /// Makes the shared connection to a server that refused one without a password: given the
    /// profile, the shared socket and ssh's refusal; true when the connection is up. Set by the app,
    /// which keeps the password or asks for it (`ServerPasswords`); without it, nothing asks.
    nonisolated(unsafe) public static var passwordSignIn: (@Sendable (ServerProfile, String, String) async -> Bool)?
    public static func refusedBeforeExecution(_ message: String) -> Bool {
        message.contains("mux_client_request_session: session request failed: Session open refused by peer")
    }
    private func dedicatedArguments(_ command: String) throws -> [String] {
        let root = (fileSocket as NSString).deletingLastPathComponent
        var info = stat()
        if lstat(root, &info) != 0 {
            if mkdir(root, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EACCES) }
            guard lstat(root, &info) == 0 else { throw POSIXError(.EACCES) }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
        return ["-o", "BatchMode=yes", "-o", "ControlPersist=60"] + SSHArguments.common(profile, socket: fileSocket) + ["-T", "--", profile.host, command]
    }
    public func run(command: String, operation: ([String]) async throws -> Void) async throws {
        if prefersFiles || !FileManager.default.fileExists(atPath: sharedSocket) {
            do { try await operation(dedicatedArguments(command)) }
            catch {
                // A server that takes a password and not a key: the shared connection is made with the
                // password, and the command goes through it.
                let message = error.localizedDescription
                guard !Task.isCancelled, ServerPasswords.account(refused: message) != nil, let signIn = Self.passwordSignIn,
                      await signIn(profile, sharedSocket, message) else { throw error }
                try Task.checkCancellation()
                try await operation(SSHArguments.probe(profile, socket: sharedSocket, command: command))
                prefersFiles = false
                return
            }
            prefersFiles = true
            return
        }
        do {
            try await operation(SSHArguments.probe(profile, socket: sharedSocket, command: command))
        } catch {
            guard Self.refusedBeforeExecution(error.localizedDescription) else { throw error }
            try Task.checkCancellation()
            try await operation(dedicatedArguments(command))
            prefersFiles = true
        }
    }
}

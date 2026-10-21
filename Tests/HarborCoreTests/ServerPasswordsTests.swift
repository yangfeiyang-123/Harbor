import XCTest
@testable import HarborCore

/// A keychain in memory.
private final class Keeper: PasswordKeeper {
    var items: [String: [String: String]] = [:]
    func password(service: String, account: String) -> String? { items[service]?[account] }
    func keep(_ password: String, service: String, account: String, label: String) -> Bool { items[service, default: [:]][account] = password; return true }
    func remove(service: String, account: String?) -> Bool {
        guard let account else { return items.removeValue(forKey: service) != nil }
        return items[service]?.removeValue(forKey: account) != nil
    }
    func contains(service: String) -> Bool { !(items[service] ?? [:]).isEmpty }
}

/// What the terminal was asked, and what is typed there.
private final class Terminal {
    var typed: [String?] = []
    var asked: [(String, Bool)] = []
    func ask(_ prompt: String, _ echo: Bool) -> String? { asked.append((prompt, echo)); return typed.isEmpty ? nil : typed.removeFirst() }
}

final class ServerPasswordsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-askpass-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func question(_ server: UUID, _ connection: String, _ keeper: Keeper, _ terminal: Terminal) -> Askpass {
        Askpass(server: server, connection: connection, keeper: keeper, directory: directory, ask: terminal.ask, note: { _ in })
    }

    func testThePasswordQuestionsOfOpenSSHAreToldFromItsOtherQuestions() {
        XCTAssertEqual(ServerPasswords.account(asked: "ubuntu@192.0.2.10's password: "), "ubuntu@192.0.2.10")
        XCTAssertEqual(ServerPasswords.account(asked: "(ubuntu@gpu-4090) Password: "), "ubuntu@gpu-4090")
        XCTAssertEqual(ServerPasswords.account(asked: "(ubuntu@gpu-4090) Password:"), "ubuntu@gpu-4090")
        XCTAssertNil(ServerPasswords.account(asked: "(ubuntu@gpu-4090) Verification code: "))
        XCTAssertNil(ServerPasswords.account(asked: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "))
        XCTAssertNil(ServerPasswords.account(asked: "The authenticity of host '[127.0.0.1]:2299' can't be established.\nED25519 key fingerprint is SHA256:x.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "))
        XCTAssertNil(ServerPasswords.account(asked: "Password: "), "without whom it is for, a password is not kept")
    }

    func testTerminalsRunSSHWithHarborAsItsAskpassProgram() {
        let server = UUID()
        let env = ServerPasswords.environment(server: server, executable: "/Applications/Harbor.app/Contents/MacOS/HarborSSH", connection: "c1")
        XCTAssertEqual(env["SSH_ASKPASS"], "/Applications/Harbor.app/Contents/MacOS/HarborSSH")
        XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(env[ServerPasswords.variable], server.uuidString + " c1")
    }

    func testAPasswordIsAskedOnceAndGivenAfterItsConnectionWasMade() {
        let server = UUID(), keeper = Keeper(), terminal = Terminal()
        let prompt = "ubuntu@192.0.2.10's password: "
        terminal.typed = ["secret"]
        XCTAssertEqual(question(server, "c1", keeper, terminal).answer(prompt), "secret")
        XCTAssertEqual(terminal.asked.count, 1); XCTAssertEqual(terminal.asked[0].1, false, "a password is not shown as it is typed")
        XCTAssertEqual(keeper.password(service: ServerPasswords.service(server), account: "ubuntu@192.0.2.10"), "secret")
        ServerPasswords.confirm(server: server, directory: directory)
        // Every later connection: given, not asked.
        for connection in ["c2", "c3"] { XCTAssertEqual(question(server, connection, keeper, terminal).answer(prompt), "secret") }
        XCTAssertEqual(terminal.asked.count, 1)
        // Another server, or another account on it, is asked for its own.
        terminal.typed = ["other"]
        XCTAssertEqual(question(UUID(), "c4", keeper, terminal).answer(prompt), "other")
        terminal.typed = ["root's"]
        XCTAssertEqual(question(server, "c5", keeper, terminal).answer("root@192.0.2.10's password: "), "root's")
        XCTAssertEqual(terminal.asked.count, 3)
    }

    func testAPasswordTheServerRefusesIsDroppedAndAskedForAgain() {
        let server = UUID(), keeper = Keeper(), terminal = Terminal()
        let prompt = "ubuntu@host's password: ", service = ServerPasswords.service(server)
        _ = keeper.keep("old", service: service, account: "ubuntu@host", label: "")
        let connection = question(server, "c1", keeper, terminal)
        XCTAssertEqual(connection.answer(prompt), "old")
        XCTAssertTrue(terminal.asked.isEmpty)
        // ssh asks again in the same connection: "old" was refused.
        terminal.typed = ["typo", "new"]
        XCTAssertEqual(connection.answer(prompt), "typo")
        XCTAssertEqual(keeper.password(service: service, account: "ubuntu@host"), "typo")
        XCTAssertEqual(connection.answer(prompt), "new")
        XCTAssertEqual(keeper.password(service: service, account: "ubuntu@host"), "new")
        ServerPasswords.confirm(server: server, directory: directory)
        XCTAssertEqual(question(server, "c2", keeper, terminal).answer(prompt), "new")
        XCTAssertEqual(terminal.asked.count, 2)
    }

    func testAPasswordTypedForAConnectionThatWasNeverMadeIsNotGiven() {
        let server = UUID(), keeper = Keeper(), terminal = Terminal()
        let prompt = "ubuntu@host's password: "
        terminal.typed = ["wrong"]
        XCTAssertEqual(question(server, "c1", keeper, terminal).answer(prompt), "wrong")
        // c1 ended without a connection: the next one asks rather than sending a password that may be wrong.
        terminal.typed = ["right"]
        XCTAssertEqual(question(server, "c2", keeper, terminal).answer(prompt), "right")
        XCTAssertEqual(terminal.asked.count, 2)
        ServerPasswords.confirm(server: server, directory: directory)
        XCTAssertEqual(question(server, "c3", keeper, terminal).answer(prompt), "right")
        XCTAssertEqual(terminal.asked.count, 2)
    }

    func testOtherQuestionsAreAskedInTheTerminalAndNothingIsKept() {
        let server = UUID(), keeper = Keeper(), terminal = Terminal()
        terminal.typed = ["yes", "passphrase", ""]
        XCTAssertEqual(question(server, "c1", keeper, terminal).answer("Are you sure you want to continue connecting (yes/no/[fingerprint])? "), "yes")
        XCTAssertEqual(question(server, "c1", keeper, terminal).answer("Enter passphrase for key '/k': "), "passphrase")
        XCTAssertEqual(terminal.asked.map { $0.1 }, [true, false], "yes or no is shown as it is typed, a passphrase is not")
        // An empty password (Return alone) is given to ssh but not kept.
        XCTAssertEqual(question(server, "c1", keeper, terminal).answer("u@h's password: "), "")
        XCTAssertTrue(keeper.items.isEmpty)
        // No one to ask: no answer, and ssh gives up on this question.
        XCTAssertNil(question(server, "c2", keeper, terminal).answer("u@h's password: "))
    }

    func testARefusalSaysWhomAPasswordWouldBeFor() {
        XCTAssertEqual(ServerPasswords.account(refused: "ubuntu@192.0.2.10: Permission denied (publickey,password)."), "ubuntu@192.0.2.10")
        XCTAssertEqual(ServerPasswords.account(refused: "Warning: Permanently added 'h' (ED25519) to the list of known hosts.\r\nroot@h: Permission denied (publickey,keyboard-interactive).\r\n"), "root@h")
        XCTAssertNil(ServerPasswords.account(refused: "git@github.com: Permission denied (publickey)."), "a server that takes keys only is not asked a password for")
        XCTAssertNil(ServerPasswords.account(refused: "ssh: connect to host h port 22: Connection refused"))
        XCTAssertNil(ServerPasswords.account(refused: "mkdir: cannot create directory '/x': Permission denied"))
        let env = ServerPasswords.environment(server: UUID(), executable: "/x", connection: "c1", background: true)
        XCTAssertTrue(env[ServerPasswords.variable]?.hasSuffix(" c1 background") == true)
    }

    func testAPasswordTypedInTheDialogIsGivenToItsConnectionAndThenToEveryOne() {
        let server = UUID(), keeper = Keeper(), terminal = Terminal(), account = "ubuntu@h", prompt = "ubuntu@h's password: "
        func background(_ connection: String) -> Askpass {
            Askpass(server: server, connection: connection, keeper: keeper, directory: directory, background: true, ask: terminal.ask, note: { _ in })
        }
        XCTAssertFalse(ServerPasswords.usable(server: server, account: account, keeper: keeper, directory: directory))
        XCTAssertTrue(ServerPasswords.offer("typo", server: server, account: account, connection: "d1", keeper: keeper, directory: directory))
        XCTAssertFalse(ServerPasswords.usable(server: server, account: account, keeper: keeper, directory: directory), "not before its connection was made")
        let first = background("d1")
        XCTAssertEqual(first.answer(prompt), "typo")
        // Refused (ssh asks again): nothing more is given, and with no terminal nothing is asked.
        XCTAssertNil(first.answer(prompt))
        XCTAssertTrue(terminal.asked.isEmpty)
        XCTAssertNil(keeper.password(service: ServerPasswords.service(server), account: account))
        // Typed again; this time the connection is made.
        XCTAssertTrue(ServerPasswords.offer("right", server: server, account: account, connection: "d2", keeper: keeper, directory: directory))
        XCTAssertEqual(background("d2").answer(prompt), "right")
        ServerPasswords.confirm(server: server, directory: directory)
        XCTAssertTrue(ServerPasswords.usable(server: server, account: account, keeper: keeper, directory: directory))
        XCTAssertEqual(background("d3").answer(prompt), "right")
        XCTAssertEqual(question(server, "t1", keeper, terminal).answer(prompt), "right", "a terminal is given it too")
        XCTAssertTrue(terminal.asked.isEmpty)
        // Nothing else is answered without a terminal: a new host key is not accepted from here.
        XCTAssertNil(background("d4").answer("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        XCTAssertTrue(terminal.asked.isEmpty)
        ServerPasswords.drop(server: server, account: account, keeper: keeper, directory: directory)
        XCTAssertFalse(ServerPasswords.usable(server: server, account: account, keeper: keeper, directory: directory))
    }

    func testAnSSHThatAsksNothingUsesTheKeptPasswordAndIsOtherwiseLeftAsItWas() {
        let server = UUID(), keeper = Keeper()
        let arguments = ["-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "h"]
        let plain = ServerPasswords.quiet(arguments, server: server, executable: "/x", keeper: keeper)
        XCTAssertEqual(plain.arguments, arguments, "a server with keys only is reached as before")
        XCTAssertNil(plain.environment)
        _ = keeper.keep("secret", service: ServerPasswords.service(server), account: "u@h", label: "")
        let quiet = ServerPasswords.quiet(arguments, server: server, executable: "/x", keeper: keeper)
        XCTAssertEqual(quiet.arguments, ["-N", "-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=10", "--", "h"])
        XCTAssertEqual(quiet.environment?["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(quiet.environment?[ServerPasswords.variable]?.hasSuffix(" background"), true, "nothing is asked: there is no terminal")
        let everything = quiet.arguments + (quiet.environment.map { Array($0.values) } ?? [])
        XCTAssertFalse(everything.joined().contains("secret"), "the password is never in the arguments or the environment")
    }

    func testForgettingAServerRemovesItsPasswords() {
        let server = UUID(), other = UUID(), keeper = Keeper(), terminal = Terminal()
        terminal.typed = ["a", "b", "c"]
        _ = question(server, "c1", keeper, terminal).answer("u@h's password: ")
        _ = question(server, "c1", keeper, terminal).answer("v@h's password: ")
        _ = question(other, "c2", keeper, terminal).answer("u@h's password: ")
        XCTAssertTrue(ServerPasswords.kept(server: server, keeper: keeper))
        XCTAssertTrue(ServerPasswords.forget(server: server, keeper: keeper, directory: directory))
        XCTAssertFalse(ServerPasswords.kept(server: server, keeper: keeper))
        XCTAssertTrue(ServerPasswords.kept(server: other, keeper: keeper))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("unconfirmed-" + server.uuidString) })
    }

    /// `security` stand-in: an item is a file, as the real tool keeps it, given and printed as the real one does.
    func testTheKeychainToolKeepsAnyPasswordWhole() throws {
        let tool = directory.appendingPathComponent("security")
        try """
        #!/usr/bin/python3
        import os, sys, hashlib
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'items')
        os.makedirs(root, exist_ok=True)
        command, rest = sys.argv[1], sys.argv[2:]
        options, flags, i = {}, set(), 0
        while i < len(rest):
            if rest[i] in ('-U',): flags.add(rest[i]); i += 1
            elif rest[i] == '-w' and i + 1 == len(rest): flags.add('-w'); i += 1
            else: options[rest[i]] = rest[i + 1]; i += 2
        def name(s, a): return os.path.join(root, hashlib.sha256((s + '\\n' + a).encode()).hexdigest())
        def matches(s, a):
            found = []
            for n in sorted(os.listdir(root)):
                fs, fa, fw = open(os.path.join(root, n)).read().split('\\n', 2)
                if fs == s and (a is None or fa == a): found.append((n, fw))
            return found
        if command == 'add-generic-password':
            path = name(options['-s'], options['-a'])
            if os.path.exists(path) and '-U' not in flags: sys.exit(45)
            open(path, 'w').write(options['-s'] + '\\n' + options['-a'] + '\\n' + options['-w'])
        elif command == 'find-generic-password':
            found = matches(options['-s'], options.get('-a'))
            if not found: sys.exit(44)
            print(found[0][1] if '-w' in flags else 'keychain: "login.keychain-db"')
        elif command == 'delete-generic-password':
            found = matches(options['-s'], options.get('-a'))
            if not found: sys.exit(44)
            os.remove(os.path.join(root, found[0][0]))
        """.write(to: tool, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(tool.path, 0o700), 0)
        let keychain = KeychainTool(path: tool.path), service = ServerPasswords.service(UUID())
        for password in ["plain", "with space", "-starts-with-dash", "naïve 密码 \"quoted\" 'single' \\ back", "deadbeef"] {
            XCTAssertTrue(keychain.keep(password, service: service, account: "u@h", label: "Harbor SSH · u@h"))
            XCTAssertEqual(keychain.password(service: service, account: "u@h"), password)
        }
        XCTAssertTrue(keychain.keep("x", service: service, account: "v@h", label: ""))
        XCTAssertTrue(keychain.contains(service: service))
        XCTAssertTrue(keychain.remove(service: service, account: nil))
        XCTAssertFalse(keychain.contains(service: service))
        XCTAssertNil(keychain.password(service: service, account: "u@h"))
    }

    /// Opt-in: the real login keychain, through the real `security`.
    func testTheLoginKeychainKeepsAPassword() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_KEYCHAIN_TEST"] == "1" else { throw XCTSkip("Opt-in: set HARBOR_KEYCHAIN_TEST=1 to use the login keychain") }
        let keychain = KeychainTool(), server = UUID(), service = ServerPasswords.service(server)
        defer { keychain.remove(service: service, account: nil) }
        XCTAssertFalse(ServerPasswords.kept(server: server))
        XCTAssertTrue(keychain.keep("naïve 密码 \"q\"", service: service, account: "u@h", label: "Harbor SSH · test"))
        XCTAssertEqual(keychain.password(service: service, account: "u@h"), "naïve 密码 \"q\"")
        XCTAssertTrue(ServerPasswords.kept(server: server))
        XCTAssertTrue(ServerPasswords.forget(server: server))
        XCTAssertNil(keychain.password(service: service, account: "u@h"))
    }
}

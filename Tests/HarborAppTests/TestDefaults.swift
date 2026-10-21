import XCTest
import Foundation

/// Tests keep their preferences in suites of their own. macOS writes each suite to
/// ~/Library/Preferences and leaves an empty file there even after its contents are removed,
/// sometimes only once the test process has gone, so every run used to add dozens of files.
/// Suites made here are removed when the run ends, and again a few seconds after it.
enum TestDefaults {
    private static let lock = NSLock()
    private static var names: Set<String> = []
    private static let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
    private static let observer: Observer = {
        let observer = Observer(); XCTestObservationCenter.shared.addTestObserver(observer); return observer
    }()

    static func suite(_ name: String) -> UserDefaults? {
        lock.lock(); names.insert(name); lock.unlock()
        _ = observer
        return UserDefaults(suiteName: name)
    }

    static func removeAll() {
        lock.lock(); let all = names; names = []; lock.unlock()
        for name in all {
            UserDefaults.standard.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name + ".plist"))
        }
        // The preferences daemon may write an emptied suite back after this process has exited.
        // A detached shell outlives it and removes those files; names are checked, not trusted.
        let safe = all.filter { $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil && !$0.hasPrefix(".") && !$0.hasPrefix("-") }
        guard !safe.isEmpty else { return }
        let sweeper = Process()
        sweeper.executableURL = URL(fileURLWithPath: "/bin/sh")
        sweeper.arguments = ["-c", "sleep 8; cd \"$1\" || exit 0; shift; for name in \"$@\"; do rm -f -- \"$name.plist\"; done", "sweep", preferences.path] + safe.sorted()
        sweeper.standardInput = FileHandle.nullDevice; sweeper.standardOutput = FileHandle.nullDevice; sweeper.standardError = FileHandle.nullDevice
        try? sweeper.run()
    }

    private final class Observer: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) { TestDefaults.removeAll() }
    }
}

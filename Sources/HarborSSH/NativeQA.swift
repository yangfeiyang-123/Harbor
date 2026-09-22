import AppKit
import HarborCore

extension AppStore {
    #if DEBUG
    private static var qaRoot: String? {
        ProcessInfo.processInfo.environment["HARBOR_QA_ROOT"] ?? (Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? Bundle.main.object(forInfoDictionaryKey: "HarborQARoot") as? String : nil)
    }
    #endif
    static func launchStore() -> AppStore {
        #if DEBUG
        if let root = qaRoot {
            return AppStore(historyRoot: URL(fileURLWithPath: root).appendingPathComponent(".state"))
        }
        #endif
        return AppStore()
    }
    func loadForLaunch() async {
        #if DEBUG
        if let root = Self.qaRoot {
            if let address = ProcessInfo.processInfo.environment["HARBOR_QA_DISPLAY_URL"] {
                try? history.prepare(); loading = false
                let profile = ServerProfile(name: "Display QA", host: "display.invalid", imported: true)
                profiles = [profile]; selectWorkspace(profile.id)
                var display = RemoteDisplayProfile(serverID: profile.id)
                display.name = "MuJoCo · Live Preview"; display.preset = .web; display.address = address
                remoteDisplays.load(); _ = remoteDisplays.save(display)
                page = .display
                return
            }
            if ProcessInfo.processInfo.environment["HARBOR_QA_RECOVERY"] == "1" {
                await load()
                if sessions.isEmpty {
                    selectWorkspace(nil); currentFiles.root = root + "/WorkSpace"
                    currentFiles.enabled = false; openWorkspaceTerminal()
                }
                return
            }
            do {
                try history.prepare(); loading = false
                profiles = [ServerProfile(name: "QA Alpha", host: "alpha.invalid"), ServerProfile(name: "QA Beta", host: "beta.invalid")]
                if ProcessInfo.processInfo.environment["HARBOR_QA_RECENTS"] == "1" {
                    remember(profile: profiles[0], directory: "/home/demo/WorkSpace/Project A")
                    remember(profile: profiles[1], directory: "/home/demo/Research")
                    remember(profile: profiles[0], directory: "/home/demo/WorkSpace/Project B")
                }
                selectWorkspace(nil)
                let files = currentFiles; files.root = root + "/WorkSpace"; files.enabled = true; files.terminalVisible = true
                await files.prepare(store: self); await files.navigate(root + "/WorkSpace")
                if let entry = files.entries[files.root]?.first(where: { $0.name == "main.py" }) { await files.open(entry) }
                openWorkspaceTerminal()
            } catch { errorMessage = error.localizedDescription }
            return
        }
        #endif
        await load()
    }
}

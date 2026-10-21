import Foundation

let manager = FileManager.default
let project = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let home = manager.homeDirectoryForCurrentUser
let installed = URL(fileURLWithPath: "/Applications/Harbor.app")
let candidates: [URL] = [
    home.appendingPathComponent("Applications/HarborSSH.app"),
    URL(fileURLWithPath: "/private/tmp/Harbor Preview.app"),
    URL(fileURLWithPath: "/private/tmp/Harbor Workbench Preview.app"),
    URL(fileURLWithPath: "/private/tmp/Harbor Compact Preview.app"),
    project.appendingPathComponent("qa/Harbor Preview.app"),
    project.appendingPathComponent("dist/HarborSSH.app"),
    project.appendingPathComponent(".build/Harbor.app")
] + ((try? manager.contentsOfDirectory(at: home.appendingPathComponent("Applications"), includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".HarborSSH-previous-") }
let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
func register(_ option: String, _ url: URL) {
    let process = Process(); process.executableURL = URL(fileURLWithPath: lsregister); process.arguments = [option, url.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try? process.run(); process.waitUntilExit()
}
let info = installed.appendingPathComponent("Contents/Info.plist")
guard manager.fileExists(atPath: info.path) else { fatalError("Install the current Harbor before removing older copies.") }
var report: [[String: String]] = []
for url in candidates where manager.fileExists(atPath: url.path) {
    guard url.standardizedFileURL != installed else { fatalError("Refusing to remove the installed app.") }
    let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    guard (plist["CFBundleIdentifier"] as? String)?.hasPrefix("app.harbor.ssh") == true else { fatalError("Unexpected bundle at \(url.path)") }
    register("-u", url)
    var destination: NSURL?
    try manager.trashItem(at: url, resultingItemURL: &destination)
    report.append(["from": url.path, "trash": destination?.path ?? "Trash"])
}
register("-f", installed)
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: project.appendingPathComponent("qa/v0.5-verification/trashed-apps.json"))
print("Moved \(report.count) duplicate/old bundles to Trash. Kept /Applications/Harbor.app.")

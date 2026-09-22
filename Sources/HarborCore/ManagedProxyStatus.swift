import Foundation

public struct ManagedProxyStatus: Equatable, Sendable {
    public var values: [String: String]
    public init(output: String = "") {
        values = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
    }
    public func isUp(_ key: String) -> Bool { values[key] == "up" }
    public func verified(_ host: String) -> Bool { isUp("\(host)_TUNNEL") && values["\(host)_HTTP"] == "204" }
    public var modeLabel: String {
        switch values["MODE"] { case "usa": return "US Direct"; case "china": return "China Proxy"; default: return "Disabled" }
    }
}

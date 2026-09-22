import Foundation

/// Persist the choice on the profile so importing or reordering never changes a server's icon.
public enum ServerIcons {
    public static let symbols = [
        "server.rack", "cpu", "externaldrive", "network", "desktopcomputer",
        "cylinder.split.1x2", "shippingbox", "square.stack.3d.up", "bolt.horizontal.circle", "globe"
    ]
    public static let names = ["Rack", "Chip", "Drive", "Network", "Computer", "Database", "Container", "Cluster", "Bolt", "Globe"]

    @discardableResult public static func assignMissing(in profiles: inout [ServerProfile]) -> Bool {
        var counts = Array(repeating: 0, count: symbols.count)
        for profile in profiles {
            if let icon = profile.iconSymbol, let index = symbols.firstIndex(of: icon) { counts[index] += 1 }
        }
        var changed = false
        for index in profiles.indices where !symbols.contains(profiles[index].iconSymbol ?? "") {
            let leastUsed = counts.indices.min { counts[$0] < counts[$1] }!
            profiles[index].iconSymbol = symbols[leastUsed]; counts[leastUsed] += 1; changed = true
        }
        return changed
    }
}

public extension ServerProfile {
    var displayIcon: String { ServerIcons.symbols.contains(iconSymbol ?? "") ? iconSymbol! : ServerIcons.symbols[0] }
}

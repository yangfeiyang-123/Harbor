import Foundation
import Darwin

public struct SSHConfigEntry: Equatable, Sendable {
    public var aliases: [String]
    public var source: String
    public var primary: String { aliases[0] }
}

public enum SSHConfig {
    public static func tokens(_ line: String) -> [String] {
        var result: [String] = [], token = "", quote: Character?, escaped = false
        for c in line {
            if escaped { token.append(c); escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } else { token.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "#" { break }
            if c.isWhitespace || (c == "=" && (result.isEmpty || (result.count == 1 && token.isEmpty))) {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(c) }
        }
        if escaped { token.append("\\") }
        if !token.isEmpty { result.append(token) }
        return result
    }
    public static func entries(at url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SSHConfigEntry] {
        var seen = Set<String>(), result = [SSHConfigEntry](), aliases = Set<String>()
        func visit(_ file: URL, depth: Int) {
            guard depth < 16, seen.insert(file.standardizedFileURL.path).inserted,
                  let contents = try? String(contentsOf: file, encoding: .utf8) else { return }
            for line in contents.components(separatedBy: .newlines) {
                let t = tokens(line); guard let key = t.first?.lowercased() else { continue }
                if key == "host" {
                    let names = t.dropFirst().filter { SSHArguments.validHost($0) && !aliases.contains($0) }
                    if !names.isEmpty {
                        result.append(SSHConfigEntry(aliases: Array(names), source: file.path)); aliases.formUnion(names)
                    }
                } else if key == "include" {
                    for pattern in t.dropFirst() {
                        let expanded = pattern.hasPrefix("~/") ? home.appendingPathComponent(String(pattern.dropFirst(2))).path : pattern
                        let absolute = expanded.hasPrefix("/") ? expanded : home.appendingPathComponent(".ssh").appendingPathComponent(expanded).path
                        var g = glob_t()
                        if glob(absolute, 0, nil, &g) == 0, let paths = g.gl_pathv {
                            for i in 0..<Int(g.gl_pathc) { if let path = paths[i] { visit(URL(fileURLWithPath: String(cString: path)), depth: depth + 1) } }
                        }
                        globfree(&g)
                    }
                }
            }
        }
        visit(url, depth: 0)
        return result
    }
    public static func effective(_ text: String) -> [String: String] {
        var values = [String: String]()
        for line in text.components(separatedBy: .newlines) {
            guard let split = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<split]).lowercased()
            if values[key] == nil { values[key] = String(line[line.index(after: split)...]) }
        }
        return values
    }
}

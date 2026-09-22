import Foundation

public struct CommandBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public var command: String?
    public var prompt: String?
    public var output: String
}

/// A presentation index for existing text logs. Never changes the saved transcript.
/// Only qualified shell prompts count as command boundaries; arbitrary `$` output does not.
public enum CommandHistory {
    private static let prompt = try! NSRegularExpression(pattern:
        #"^(?:(?:\([^\r\n)]{1,80}\))\s*)?(?:\[?[\w.-]+@[\w.-]+(?::[^\r\n]*?|\s+[^\r\n]*?)\]?|(?:~|/)[^\r\n]*?)\s*[$#%] ?"#)

    public static func parse(_ transcript: String) -> [CommandBlock] {
        var blocks: [CommandBlock] = []
        var current = CommandBlock(id: 0, command: nil, prompt: nil, output: "")
        func finish() {
            current.output = current.output.trimmingCharacters(in: .newlines)
            if current.command != nil || !current.output.isEmpty { blocks.append(current) }
            current = CommandBlock(id: blocks.count, command: nil, prompt: nil, output: "")
        }
        for line in transcript.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = prompt.firstMatch(in: line, range: range), let prefix = Range(match.range, in: line) {
                let command = String(line[prefix.upperBound...]).trimmingCharacters(in: .whitespaces)
                // Old zsh logs can contain the same prompt twice when it is redrawn.
                if command == current.command && current.output.isEmpty { continue }
                finish()
                if !command.isEmpty { current.command = command; current.prompt = String(line[prefix]) }
            } else if current.command != nil && current.output.isEmpty && line.hasPrefix("> ") {
                current.command! += "\n" + line.dropFirst(2)
            } else {
                current.output += line + "\n"
            }
        }
        finish()
        return blocks
    }
}

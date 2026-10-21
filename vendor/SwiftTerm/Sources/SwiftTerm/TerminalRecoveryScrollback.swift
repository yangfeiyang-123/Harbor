import Foundation

private final class RecoveryTextDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

extension Terminal {
    /// Place a saved text snapshot above the live normal screen. The application's
    /// cursor, alternate buffer, modes and screen cells must remain untouched.
    public func prependRecoveryScrollback(_ text: String) {
        let capacity = normalBuffer.lines.maxLength - normalBuffer.lines.count
        guard capacity > 0, !text.isEmpty else { return }
        let delegate = RecoveryTextDelegate()
        let snapshot = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: 2, scrollback: capacity))
        // Keep Unicode joiners used by emoji; only strip terminal control bytes.
        let safe = String(text.unicodeScalars.filter { ($0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)) || $0 == "\n" || $0 == "\t" })
        snapshot.feed(text: safe.replacingOccurrences(of: "\n", with: "\r\n"))
        let source = snapshot.normalBuffer
        let end = min(source.lines.count, source.yBase + source.y + 1)
        let start = max(0, end - capacity)
        guard end > start else { return }
        let lines = (start..<end).map { row -> BufferLine in
            let original = source.lines[row]
            let line = BufferLine(cols: cols, isWrapped: row > start && original.isWrapped)
            for col in 0..<cols {
                let cell = original[col]
                // Grapheme IDs belong to their Terminal; do not copy foreign IDs.
                line[col] = makeCharData(attribute: cell.attribute, char: snapshot.getCharacter(for: cell), size: cell.width)
            }
            return line
        }
        normalBuffer.lines.splice(start: 0, deleteCount: 0, items: lines, change: { _ in })
        normalBuffer.yBase += lines.count
        normalBuffer.yDisp += lines.count
        updateFullScreen()
        tdel?.bufferActivated(source: self)
    }
}

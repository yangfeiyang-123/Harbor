import Foundation

/// Produces a line-oriented command transcript alongside the original output log.
/// Replays in-line edits from readline/zle instead of recording every redraw.
public struct CommandTranscriptFilter {
    private enum State { case text, escape, csi, string, stringEscape, charset }
    private var state = State.text
    private var parameters = ""
    private var unicode = Data()
    private var expectedBytes = 0
    private var cells: [String] = []
    private var cursor = 0
    private var alternate = false
    public init() {}
    public var pending: Data { Data(line.utf8) }
    private var line: String { cells.joined().replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression) }
    public mutating func consume(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            switch state {
            case .text:
                if byte == 27 { state = .escape; continue }
                guard !alternate else { continue }
                if byte == 13 { cursor = 0 }
                else if byte == 10 { output.append(Data((line + "\n").utf8)); cells = []; cursor = 0 }
                else if byte == 8 { cursor = max(0, cursor - 1) }
                else if byte == 9 { let target = min(100_000, (cursor / 8 + 1) * 8); while cursor < target { put(" ") } }
                else if byte >= 32 && byte != 127 { decode(byte) }
            case .escape:
                if byte == 91 { state = .csi; parameters = "" }
                else if [93, 80, 94, 95, 88].contains(byte) { state = .string }
                else if [40, 41, 42, 43, 35, 37].contains(byte) { state = .charset }
                else { state = .text }
            case .csi:
                if (0x40...0x7e).contains(byte) {
                    if [1049, 1047, 47].contains(Int(parameters.dropFirst()) ?? 0), parameters.hasPrefix("?"), byte == 104 || byte == 108 {
                        if byte == 104 && !alternate { output.append(Data((line + "\n[See the full log for output from fullscreen programs]\n").utf8)); cells = []; cursor = 0 }
                        alternate = byte == 104
                    } else if !alternate { control(byte) }
                    state = .text
                } else if parameters.utf8.count < 64 { parameters.append(Character(UnicodeScalar(byte))) }
            case .string:
                if byte == 7 { state = .text } else if byte == 27 { state = .stringEscape }
            case .stringEscape: state = byte == 92 ? .text : .string
            case .charset: state = .text
            }
        }
        return output
    }
    private mutating func control(_ final: UInt8) {
        let n = min(100_000, max(1, Int(parameters) ?? 1))
        switch final {
        case 67, 97: cursor = min(100_000, cursor + n) // CUF / HPR
        case 68: cursor = max(0, cursor - n)
        case 71, 96: cursor = n - 1
        case 75:
            switch Int(parameters) ?? 0 {
            case 0: if cursor < cells.count { cells.removeSubrange(cursor...) }
            case 1: for i in 0..<min(cursor + 1, cells.count) { cells[i] = " " }
            case 2: cells = []
            default: break
            }
        case 80: // delete characters
            if cursor < cells.count { cells.removeSubrange(cursor..<min(cells.count, cursor + n)) }
        case 88:
            for i in cursor..<min(max(cursor, cells.count), cursor + n) { cells[i] = " " }
        default: break
        }
    }
    private mutating func decode(_ byte: UInt8) {
        if unicode.isEmpty {
            if byte < 128 { put(String(UnicodeScalar(byte))); return }
            expectedBytes = byte >= 240 ? 4 : byte >= 224 ? 3 : byte >= 192 ? 2 : 1
        }
        unicode.append(byte)
        if unicode.count >= expectedBytes {
            let text = String(decoding: unicode, as: UTF8.self); unicode = Data()
            for scalar in text.unicodeScalars { put(String(scalar)) }
        }
    }
    private mutating func put(_ text: String) {
        guard cursor < 100_000, let scalar = text.unicodeScalars.first else { return }
        let v = scalar.value
        if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark {
            var i = min(cursor, cells.count) - 1
            while i > 0 && cells[i].isEmpty { i -= 1 }
            if i >= 0 { cells[i] += text }; return
        }
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFF).contains(v)
        let width = wide ? 2 : 1
        while cells.count < cursor + width { cells.append(" ") }
        cells[cursor] = text
        if wide { cells[cursor + 1] = "" }
        cursor += width
    }
}

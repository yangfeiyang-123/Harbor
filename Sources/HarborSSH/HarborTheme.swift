import AppKit
import SwiftUI

/// Shared with the offline CodeMirror/Markdown bundle; see Themes/SOURCES.md.
enum HarborTheme {
    struct Palette: Decodable {
        let name: String
        let colors: [String: String]
        let syntax: [String: String]
        let ansi: [String]
    }
    static let palettes: [String: Palette] = {
        let url = AppResources.directory("Themes").appendingPathComponent("vscode-2026.json")
        return try! JSONDecoder().decode([String: Palette].self, from: Data(contentsOf: url))
    }()
    static func palette(dark: Bool) -> Palette { palettes[dark ? "dark" : "light"]! }
    static func native(_ role: String, dark: Bool) -> NSColor { hex(palette(dark: dark).colors[role]!) }
    static func hex(_ value: String) -> NSColor {
        let digits = String(value.dropFirst())
        let raw = UInt32(digits, radix: 16)!
        let rgb = digits.count == 8 ? raw >> 8 : raw
        let alpha = digits.count == 8 ? Double(raw & 255) / 255 : 1
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                       blue: Double(rgb & 255) / 255, alpha: alpha)
    }
    static func adaptive(_ role: String) -> NSColor {
        NSColor(name: NSColor.Name("Harbor." + role)) { appearance in
            native(role, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }
}

extension Color {
    static let harborAccent = Color(nsColor: HarborTheme.adaptive("textLink.foreground"))
    static let harborButton = Color(nsColor: HarborTheme.adaptive("button.background"))
    static let harborForeground = Color(nsColor: HarborTheme.adaptive("foreground"))
    static let harborMuted = Color(nsColor: HarborTheme.adaptive("descriptionForeground"))
    static let harborIcon = Color(nsColor: HarborTheme.adaptive("icon.foreground"))
    static let harborBackground = Color(nsColor: HarborTheme.adaptive("panel.background"))
    static let harborSidebar = Color(nsColor: HarborTheme.adaptive("sideBar.background"))
    static let harborEditor = Color(nsColor: HarborTheme.adaptive("editor.background"))
    static let harborBorder = Color(nsColor: HarborTheme.adaptive("panel.border"))
    static let harborFocus = Color(nsColor: HarborTheme.adaptive("focusBorder"))
    static let harborSelection = Color(nsColor: HarborTheme.adaptive("list.activeSelectionBackground"))
    static let harborSelectionText = Color(nsColor: HarborTheme.adaptive("list.activeSelectionForeground"))
    static let harborHover = Color(nsColor: HarborTheme.adaptive("list.hoverBackground"))
    static let harborTabActive = Color(nsColor: HarborTheme.adaptive("tab.activeBackground"))
    static let harborTabInactive = Color(nsColor: HarborTheme.adaptive("tab.inactiveBackground"))
    static let harborTabBorder = Color(nsColor: HarborTheme.adaptive("tab.activeBorderTop"))
    static let harborSuccess = Color(nsColor: HarborTheme.adaptive("gitDecoration.addedResourceForeground"))
    static let harborWarning = Color(nsColor: HarborTheme.adaptive("list.warningForeground"))
    static let harborWidget = Color(nsColor: HarborTheme.adaptive("editorWidget.background"))
    static let harborInput = Color(nsColor: HarborTheme.adaptive("input.background"))
    static let harborInputBorder = Color(nsColor: HarborTheme.adaptive("input.border"))
}

struct HarborTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration.textFieldStyle(.plain).foregroundStyle(Color.harborForeground)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.harborInput, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.harborInputBorder, lineWidth: 1).allowsHitTesting(false))
    }
}

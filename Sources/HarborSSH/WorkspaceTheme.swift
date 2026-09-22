import AppKit
import SwiftUI

/// Scoped to Files & Code. Terminal mode and server chrome retain their theme.
enum WorkspaceTheme {
    static let palettes: [String: HarborTheme.Palette] = {
        let url = AppResources.directory("Themes").appendingPathComponent("cursor.json")
        return (try? JSONDecoder().decode([String: HarborTheme.Palette].self, from: Data(contentsOf: url))) ?? HarborTheme.palettes
    }()
    static func native(_ role: String, dark: Bool) -> NSColor {
        HarborTheme.hex(palettes[dark ? "dark" : "light"]!.colors[role] ?? "#808080")
    }
    static func color(_ role: String) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Harbor.Code." + role)) { appearance in
            native(role, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        })
    }
    static let background = color("editor.background")
    static let sidebar = color("sideBar.background")
    static let foreground = color("editor.foreground")
    static let muted = color("descriptionForeground")
    static let border = color("panel.border")
    static let selection = color("list.activeSelectionBackground")
    static let hover = color("list.hoverBackground")
}

struct WorkspaceIconButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 26, height: 26).contentShape(Rectangle())
                .background(selected ? WorkspaceTheme.selection : hovered ? WorkspaceTheme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).foregroundStyle(selected ? WorkspaceTheme.foreground : WorkspaceTheme.muted)
            .onHover { hovered = $0 }.help(title).accessibilityLabel(title)
    }
}

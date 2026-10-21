import AppKit
import SwiftUI

/// Scoped to Files & Code. Terminal mode and server chrome retain their theme.
enum WorkspaceTheme {
    static let palettes: [String: HarborTheme.Palette] = {
        let url = AppResources.directory("Themes").appendingPathComponent("cursor.json")
        return (try? JSONDecoder().decode([String: HarborTheme.Palette].self, from: Data(contentsOf: url))) ?? HarborTheme.palettes
    }()
    static func native(_ role: String, dark: Bool, selection: String = HarborTheme.selection) -> NSColor {
        // A family with palettes of its own is used as it is; the standard colors here are Cursor's.
        let family = HarborTheme.family(selection)
        let palette = (family.file == nil ? palettes : HarborTheme.lightAndDark(of: family))[dark ? "dark" : "light"]!
        return HarborTheme.hex(palette.colors[role] ?? "#808080")
    }
    static func color(_ role: String) -> Color {
        let selected = HarborTheme.selection
        return Color(nsColor: NSColor(name: NSColor.Name("Harbor.Code." + selected + "." + role)) { appearance in
            native(role, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, selection: selected)
        })
    }
    static var background: Color { color("editor.background") }
    static var sidebar: Color { color("sideBar.background") }
    static var foreground: Color { color("editor.foreground") }
    static var muted: Color { color("descriptionForeground") }
    static var border: Color { color("panel.border") }
    static var selection: Color { color("list.activeSelectionBackground") }
    static var hover: Color { color("list.hoverBackground") }
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

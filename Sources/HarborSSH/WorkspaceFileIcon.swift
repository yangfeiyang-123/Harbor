import AppKit
import CoreText
import SwiftUI

/// The same static Seti glyphs used by Cursor's default file icon theme.
/// The font and lookup tables are loaded once, never per file or over the network.
enum WorkspaceFileIcons {
    struct Icon: Decodable {
        let character: String
        let dark: String
        let light: String
    }
    private struct Theme: Decodable {
        let file: String
        let definitions: [String: Icon]
        let fileNames: [String: String]
        let fileExtensions: [String: String]
    }
    private static let directory = AppResources.directory("Themes").appendingPathComponent("Seti")
    private static let theme = try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: directory.appendingPathComponent("icons.json")))
    static let fontName: String? = {
        let url = directory.appendingPathComponent("seti.ttf") as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        CTFontManagerRegisterFontsForURL(url, .process, nil)
        let name = CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor(descriptor, 24, nil)) as String
        return NSFont(name: name, size: 24) == nil ? nil : name
    }()
    static func icon(for path: String) -> Icon? {
        guard let theme else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        if let key = theme.fileNames[name] { return theme.definitions[key] }
        // Prefer compound extensions such as .d.ts over .ts. Dotfiles also
        // match, e.g. .bashrc. Unknown types use Seti's plain document glyph.
        var suffix = name[...]
        while let dot = suffix.firstIndex(of: ".") {
            suffix = suffix[suffix.index(after: dot)...]
            if let key = theme.fileExtensions[String(suffix)] { return theme.definitions[key] }
        }
        return theme.definitions[theme.file]
    }
}

struct WorkspaceFileIcon: View {
    let path: String
    var directory = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if directory {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(WorkspaceTheme.muted)
            } else if let icon = WorkspaceFileIcons.icon(for: path), let font = WorkspaceFileIcons.fontName {
                Text(icon.character).font(.custom(font, size: 24)).fixedSize()
                    .foregroundStyle(Color(nsColor: HarborTheme.hex(colorScheme == .dark ? icon.dark : icon.light)))
            } else {
                Image(systemName: "doc").font(.system(size: 13)).foregroundStyle(WorkspaceTheme.muted)
            }
        }.frame(width: 18, height: 18).accessibilityHidden(true).allowsHitTesting(false)
    }
}

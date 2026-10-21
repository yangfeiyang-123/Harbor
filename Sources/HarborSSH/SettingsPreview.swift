import SwiftUI
import CoreText
import AppKit

/// What the preview draws from: every option that is visible in a miniature.
struct PreviewOptions: Equatable {
    enum Focus { case workbench, editor, terminal }
    var focus = Focus.workbench
    var selection = HarborTheme.defaultAppearance
    var dark = false
    var glass = false
    var interfaceFont = 13.0
    var activityCount = 4
    var breadcrumbs = true
    var tabs = "multiple"
    var editorFamily = "Menlo, Monaco, monospace"
    var editorFont = 13.0
    var editorLineHeight = 0.0
    var cursorStyle = "line"
    var cursorBlinking = "blink"
    var wrap = false
    var tabSize = 4
    var lineNumbers = "on"
    var minimap = false
    var whitespace = "selection"
    var bracketColors = true
    var terminalFamily = ""
    var terminalFont = 13.0
    var terminalLineHeight = 1.0
    var terminalCursor = "block"
    var terminalBlink = false
    var replay = 0
}

extension HarborTypography {
    /// The first installed family of a CSS-style list ("JetBrains Mono, Menlo, monospace").
    static func family(in list: String) -> String? {
        for part in list.split(separator: ",") {
            let name = part.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            if !name.isEmpty, NSFontManager.shared.availableMembers(ofFontFamily: name)?.isEmpty == false { return name }
        }
        return nil
    }
    static func monospaced(_ list: String, size: Double) -> NSFont {
        family(in: list).flatMap { NSFont(name: $0, size: size) ?? NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    /// Installed fixed-pitch families, the familiar ones first.
    /// Fixed-pitch families on this Mac. Looking at every installed font takes a while, so this
    /// uses Core Text, which may be asked from a background thread ahead of time.
    static let monospacedFamilies: [String] = {
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).filter { !$0.hasPrefix(".") }
        let fixed = families.filter { family in
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any],
                  let symbolic = traits[kCTFontSymbolicTrait] as? UInt32 else { return false }
            return CTFontSymbolicTraits(rawValue: symbolic).contains(.traitMonoSpace)
        }
        let preferred = ["Menlo", "SF Mono", "Monaco", "JetBrains Mono", "Fira Code", "Source Code Pro", "Cascadia Code", "IBM Plex Mono", "Hack"].filter(fixed.contains)
        return preferred + fixed.filter { !preferred.contains($0) }.sorted()
    }()
}

/// A text cursor that looks and blinks the way the chosen options make it.
struct PreviewCursor: View {
    let style: String
    let blinking: String
    let color: Color
    let cell: CGSize

    var body: some View {
        Group {
            if blinking == "blink" {
                // On and off: two drawings a second, on the half periods, instead of thirty.
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.53)) { timeline in cursor(at: timeline.date) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: blinking == "solid")) { timeline in cursor(at: timeline.date) }
            }
        }
        .frame(width: cell.width, height: cell.height, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    private func cursor(at date: Date) -> some View {
            // A hair past the instant, so a drawing made exactly on a half period lands in the right half.
            let phase = (date.timeIntervalSinceReferenceDate + 0.001).truncatingRemainder(dividingBy: 1.06) / 1.06
            let wave = 0.5 + 0.5 * cos(phase * 2 * .pi)
            let opacity: Double = {
                switch blinking {
                case "blink": return phase < 0.5 ? 1 : 0
                case "smooth": return wave
                case "phase": return pow(wave, 2.2)
                default: return 1
                }
            }()
            return shape.opacity(opacity).scaleEffect(x: 1, y: blinking == "expand" ? max(0.08, wave) : 1, anchor: .center)
    }

    @ViewBuilder private var shape: some View {
        switch style {
        case "block": Rectangle().fill(color.opacity(0.85)).frame(width: cell.width, height: cell.height)
        case "block-outline": Rectangle().stroke(color, lineWidth: 1).frame(width: cell.width - 1, height: cell.height - 1)
        case "underline": Rectangle().fill(color).frame(width: cell.width, height: 2)
        case "underline-thin": Rectangle().fill(color).frame(width: cell.width, height: 1)
        case "line-thin": Rectangle().fill(color).frame(width: 1, height: cell.height)
        default: Rectangle().fill(color).frame(width: 2, height: cell.height)
        }
    }
}

/// A miniature workbench rendered natively from a palette. It never touches a
/// real terminal or editor, so previewing a theme, font or cursor is free.
struct SettingsPreview: View {
    let options: PreviewOptions

    private var palette: HarborTheme.Palette { HarborTheme.palette(dark: options.dark, selection: options.selection) }
    /// Roles a palette may leave to the editor's defaults, and what stands in for them here.
    private static let fallbacks = ["breadcrumb.background": "editor.background", "breadcrumb.foreground": "descriptionForeground", "minimap.background": "editor.background",
        "editorWhitespace.foreground": "editorLineNumber.foreground", "panelTitle.activeForeground": "foreground", "statusBarItem.remoteBackground": "statusBar.background",
        "statusBarItem.remoteForeground": "statusBar.foreground", "list.activeSelectionIconForeground": "icon.foreground", "activityBar.foreground": "foreground",
        "activityBar.inactiveForeground": "descriptionForeground", "editorCursor.foreground": "foreground", "editorLineNumber.activeForeground": "foreground",
        "editor.lineHighlightBackground": "editor.background", "terminalCursor.foreground": "foreground"]
    private func color(_ role: String) -> Color {
        if let value = palette.colors[role] ?? Self.fallbacks[role].flatMap({ palette.colors[$0] }) { return Color(nsColor: HarborTheme.hex(value)) }
        // Bracket colors follow the syntax palette when a theme does not name them.
        if role.hasPrefix("editorBracketHighlight") { return syntax(role.hasSuffix("1") ? "function" : "type") }
        return Color(nsColor: HarborTheme.hex("#808080"))
    }
    private func syntax(_ key: String) -> Color { Color(nsColor: HarborTheme.hex(palette.syntax[key] ?? "#808080")) }
    private func ansi(_ index: Int) -> Color { Color(nsColor: HarborTheme.hex(palette.ansi[index])) }
    private var ui: Double { min(max(options.interfaceFont, 11), 20) * 11 / 13 }

    private typealias Token = (String, String)
    /// One level of indentation, in the chosen tab size.
    private var indent: String { String(repeating: " ", count: min(max(options.tabSize, 1), 8)) }
    private var code: [[Token]] {
        [[("# Greet every agent docked in the harbor, one line at a time", "comment")],
         [("def ", "keyword"), ("greet", "function"), ("(", "bracket1"), ("agents: ", "variable"), ("list", "type"), ("[", "bracket2"), ("str", "type"), ("]", "bracket2"), (")", "bracket1"), (" -> ", "operator"), ("None", "constant"), (":", "operator")],
         [(indent, "space"), ("for ", "keyword"), ("name ", "variable"), ("in ", "keyword"), ("agents:", "variable")],
         [(indent + indent, "space"), ("print", "function"), ("(", "bracket1"), ("f\"hello, {name}\"", "string"), (")", "bracket1")],
         [("", "variable")],
         [("greet", "function"), ("(", "bracket1"), ("[", "bracket2"), ("\"claude\"", "string"), (", ", "operator"), ("\"codex\"", "string"), (", ", "operator"), ("\"grok\"", "string"), (", ", "operator"), ("\"gemini\"", "string"), ("]", "bracket2"), (")", "bracket1")]]
    }
    private func tokenColor(_ kind: String) -> Color {
        switch kind {
        case "bracket1": return options.bracketColors ? color("editorBracketHighlight.foreground1") : syntax("operator")
        case "bracket2": return options.bracketColors ? color("editorBracketHighlight.foreground2") : syntax("operator")
        case "space": return color("editorWhitespace.foreground")
        default: return syntax(kind)
        }
    }

    var body: some View {
        let border = color("panel.border")
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(border).frame(height: 1)
            // Unwrapped code keeps its natural width; pin the column so long
            // lines are clipped like a real editor instead of widening the pane.
            GeometryReader { proxy in
                let side = options.focus == .workbench ? 118.0 : 0
                let column = max(0, proxy.size.width - side - (side > 0 ? 1 : 0))
                HStack(spacing: 0) {
                    if side > 0 {
                        sidebar.frame(width: side)
                        Rectangle().fill(border).frame(width: 1)
                    }
                    VStack(spacing: 0) {
                        if options.focus != .terminal {
                            if options.tabs != "none" { tabs.frame(width: column, alignment: .leading) }
                            if options.breadcrumbs { breadcrumbs.frame(width: column, alignment: .leading) }
                            editor.frame(width: column, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .topLeading).clipped()
                        }
                        if options.focus != .editor {
                            if options.focus != .terminal { Rectangle().fill(border).frame(height: 1) }
                            terminal.frame(width: column, alignment: .topLeading)
                                .frame(maxHeight: options.focus == .terminal ? .infinity : nil, alignment: .topLeading)
                                .background(color("terminal.background")).clipped()
                        }
                    }.frame(width: column)
                }
            }
            Rectangle().fill(border).frame(height: 1)
            statusBar
        }
        .background(color("editor.background"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(border, lineWidth: 1))
        .shadow(color: .black.opacity(options.dark ? 0.35 : 0.10), radius: 14, y: 6)
        .environment(\.colorScheme, options.dark ? .dark : .light)
        .animation(HarborMotion.animation(HarborMotion.standard), value: options.selection)
        .animation(HarborMotion.animation(HarborMotion.standard), value: options.dark)
        .animation(HarborMotion.animation(HarborMotion.quick), value: options.focus)
        .accessibilityElement(children: .ignore).accessibilityLabel("Preview of the workbench with the current settings")
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(color("descriptionForeground").opacity(0.35)).frame(width: 8, height: 8) }
                Spacer()
            }.padding(.leading, 10)
            Text("harbor-demo").font(.system(size: ui, weight: .medium)).foregroundStyle(color("descriptionForeground"))
        }.frame(height: 26).background(color("titleBar.activeBackground"))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            // The row of views above Explorer: the first ones stay, the rest sit behind the arrow.
            HStack(spacing: 0) {
                let symbols = ["doc.on.doc", "magnifyingglass", "arrow.triangle.branch", "puzzlepiece.extension", "ladybug", "shippingbox", "sparkle", "clock"]
                let shown = min(max(options.activityCount, 1), 6)
                ForEach(0..<shown, id: \.self) { index in
                    Image(systemName: symbols[index % symbols.count]).font(.system(size: ui * 0.82))
                        .foregroundStyle(color(index == 0 ? "activityBar.foreground" : "activityBar.inactiveForeground"))
                        .frame(maxWidth: .infinity)
                }
                Image(systemName: "chevron.down").font(.system(size: ui * 0.6, weight: .semibold)).foregroundStyle(color("activityBar.inactiveForeground")).frame(width: 12)
            }.padding(.horizontal, 5).frame(height: ui + 13)
            Rectangle().fill(color("panel.border")).frame(height: 1)
            Text("EXPLORER").font(.system(size: ui * 0.82, weight: .semibold)).foregroundStyle(color("descriptionForeground")).padding(.horizontal, 8).padding(.vertical, 6)
            row("chevron.right", "src", selected: false)
            row("doc.text", "main.py", selected: true)
            row("doc.text", "README.md", selected: false)
            row("chevron.right", "tests", selected: false)
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity, alignment: .top).background(color("sideBar.background"))
    }

    private func row(_ symbol: String, _ name: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: ui * 0.72)).frame(width: 12)
                .foregroundStyle(color(selected ? "list.activeSelectionIconForeground" : "icon.foreground"))
            Text(name).font(.system(size: ui)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color(selected ? "list.activeSelectionForeground" : "sideBar.foreground"))
        .padding(.horizontal, 8).frame(height: ui + 11)
        .background {
            if selected {
                if options.glass { RoundedRectangle(cornerRadius: 5).fill(.ultraThinMaterial).overlay(RoundedRectangle(cornerRadius: 5).fill(color("focusBorder").opacity(0.16))).padding(.horizontal, 3) }
                else { color("list.activeSelectionBackground") }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tab("main.py", active: true)
            if options.tabs == "multiple" { tab("README.md", active: false) }
            Spacer(minLength: 0)
        }.frame(height: ui + 15).background(color("tab.inactiveBackground"))
            .overlay(alignment: .bottom) { Rectangle().fill(color("panel.border")).frame(height: 1) }
    }

    private func tab(_ name: String, active: Bool) -> some View {
        Text(name).font(.system(size: ui)).foregroundStyle(color(active ? "tab.activeForeground" : "tab.inactiveForeground"))
            .padding(.horizontal, 11).frame(maxHeight: .infinity)
            .background(color(active ? "tab.activeBackground" : "tab.inactiveBackground"))
            .overlay(alignment: .top) { if active { Rectangle().fill(color("tab.activeBorderTop")).frame(height: 1.5) } }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Text("src"); Image(systemName: "chevron.right").font(.system(size: ui * 0.55)); Text("main.py")
            Image(systemName: "chevron.right").font(.system(size: ui * 0.55)); Text("greet")
            Spacer(minLength: 0)
        }.font(.system(size: ui * 0.9)).foregroundStyle(color("breadcrumb.foreground")).lineLimit(1)
            .padding(.horizontal, 10).frame(height: ui + 9).background(color("breadcrumb.background"))
    }

    private func lineNumber(_ index: Int, current: Int) -> String {
        switch options.lineNumbers {
        case "off": return ""
        case "relative": return index == current ? "\(index + 1)" : "\(abs(index - current))"
        case "interval": return index == current || (index + 1) % 10 == 0 ? "\(index + 1)" : ""
        default: return "\(index + 1)"
        }
    }

    private var editor: some View {
        let size = min(max(options.editorFont, 6), 40)
        let font = HarborTypography.monospaced(options.editorFamily, size: size)
        let natural = Double(font.ascender - font.descender + font.leading)
        // Code-OSS: 0 follows the font, below 8 multiplies the font size, anything else is pixels.
        let line = options.editorLineHeight <= 0 ? max(natural, size * 1.35) : options.editorLineHeight < 8 ? options.editorLineHeight * size : options.editorLineHeight
        let cell = CGSize(width: Double(("0" as NSString).size(withAttributes: [.font: font]).width), height: max(natural, min(line, natural * 1.25)))
        let current = 3
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(code.enumerated()), id: \.offset) { index, tokens in
                    HStack(alignment: .center, spacing: 0) {
                        if options.lineNumbers != "off" {
                            Text(lineNumber(index, current: current)).font(Font(font))
                                .foregroundStyle(color(index == current ? "editorLineNumber.activeForeground" : "editorLineNumber.foreground"))
                                .frame(width: cell.width * 2.4, alignment: .trailing).padding(.trailing, cell.width * 1.6)
                        }
                        tokens.reduce(Text("")) { text, token in
                            let shown = token.1 == "space" ? (options.whitespace == "all" || options.whitespace == "boundary" ? String(repeating: "·", count: token.0.count) : token.0) : token.0
                            return text + Text(shown).foregroundColor(tokenColor(token.1)).italic(token.1 == "comment" && !HarborTheme.isStandard(options.selection))
                        }
                        .font(Font(font))
                        .lineLimit(options.wrap ? nil : 1).fixedSize(horizontal: !options.wrap, vertical: true)
                        if index == current { PreviewCursor(style: options.cursorStyle, blinking: options.cursorBlinking, color: color("editorCursor.foreground"), cell: cell) }
                    }
                    .frame(minHeight: line, alignment: .center)
                    .background(index == current ? color("editor.lineHighlightBackground") : .clear)
                    .harborReveal(index, distance: 6, trigger: options.replay)
                }
            }.padding(.vertical, 8).padding(.leading, options.lineNumbers == "off" ? 12 : 6)
            Spacer(minLength: 0)
            if options.minimap {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array([0.8, 0.62, 0.4, 0.5, 0.0, 0.7].enumerated()), id: \.offset) { index, width in
                        RoundedRectangle(cornerRadius: 1).fill(syntax(["comment", "keyword", "variable", "function", "variable", "function"][index]).opacity(0.55)).frame(width: 34 * width, height: 2)
                    }
                    Spacer(minLength: 0)
                }.padding(6).frame(width: 46, alignment: .leading).frame(maxHeight: .infinity)
                    .background(color("minimap.background")).overlay(alignment: .leading) { Rectangle().fill(color("panel.border")).frame(width: 1) }
            }
        }.clipped()
    }

    private var terminal: some View {
        let size = min(max(options.terminalFont, 6), 40)
        let font = HarborTypography.monospaced(options.terminalFamily.isEmpty ? options.editorFamily : options.terminalFamily, size: size)
        let natural = Double(font.ascender - font.descender + font.leading)
        let line = natural * min(max(options.terminalLineHeight, 1), 3)
        let cell = CGSize(width: Double(("0" as NSString).size(withAttributes: [.font: font]).width), height: natural)
        let ink = color("terminal.foreground")
        let prompt = Text("~/harbor-demo").foregroundColor(ansi(4)) + Text(" $ ").foregroundColor(ansi(8))
        var lines: [Text] = [prompt + Text("git status --short").foregroundColor(ink),
                             Text(" M ").foregroundColor(ansi(1)) + Text("main.py").foregroundColor(ink),
                             Text("?? ").foregroundColor(ansi(3)) + Text("notes.md").foregroundColor(ink)]
        if options.focus == .terminal {
            lines += [prompt + Text("ls").foregroundColor(ink),
                      Text("src").foregroundColor(ansi(4)) + Text("  tests").foregroundColor(ansi(4)) + Text("  main.py  README.md").foregroundColor(ink),
                      prompt + Text("python main.py").foregroundColor(ink),
                      Text("hello, claude").foregroundColor(ansi(2)), Text("hello, codex").foregroundColor(ansi(2))]
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text("TERMINAL").font(.system(size: ui * 0.82, weight: .semibold)).foregroundStyle(color("panelTitle.activeForeground"))
                .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 5)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, text in text.frame(height: line, alignment: .center) }
                HStack(spacing: 0) {
                    prompt + Text("claude").foregroundColor(ansi(2)) + Text(" ")
                    PreviewCursor(style: options.terminalCursor, blinking: options.terminalBlink ? "blink" : "solid", color: color("terminalCursor.foreground"), cell: cell)
                }.frame(height: line, alignment: .center)
            }
            .font(Font(font)).lineLimit(1).fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10).padding(.bottom, 10)
        }.frame(maxWidth: .infinity, alignment: .leading).clipped()
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: ui * 0.7, weight: .semibold)).foregroundStyle(color("statusBarItem.remoteForeground"))
                .frame(width: ui + 14).frame(maxHeight: .infinity).background(color("statusBarItem.remoteBackground"))
            Label("main", systemImage: "arrow.triangle.branch"); Spacer(); Text("Ln 4, Col 33"); Text("Python").padding(.trailing, 10)
        }.font(.system(size: ui * 0.9)).foregroundStyle(color("statusBar.foreground"))
            .frame(height: ui + 11).background(color("statusBar.background"))
    }
}

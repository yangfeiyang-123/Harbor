import SwiftUI
import AppKit
import IOSurface

/// The start page's interactive scene: four command-line agents start in their own
/// terminal cards while their dolls gather on the quay below. It is drawn by Harbor (no video
/// file or web view), frame by frame onto a surface of its own (`AgentHarborSurface`). The clock
/// stops while the window is inactive, while something lies over the page, or with motion
/// reduced, and the settled scene stays visible.
struct AgentHarborAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(HarborMotion.preferenceKey) private var stored = HarborMotion.Level.full.rawValue
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    // A picture the user chose for a doll replaces Harbor's drawing of it (Settings ▸ Appearance).
    @AppStorage("startDoll_claude") private var dollClaude = ""
    @AppStorage("startDoll_codex") private var dollCodex = ""
    @AppStorage("startDoll_grok") private var dollGrok = ""
    @AppStorage("startDoll_gemini") private var dollGemini = ""
    @State private var start = Date()
    /// The window has been the active one at some point since the scene appeared.
    @State private var everActive = false
    /// The window was still behind others a moment after the scene appeared: it shows the
    /// finished scene and keeps it. Until that is known the scene plays, so a window that is
    /// just coming forward (every launch) never shows an empty quay or starts over.
    @State private var background = false
    /// Where the scene's clock was stopped while something lies over the page, and when.
    @State private var held: (time: Double, since: Date)?
    @State private var pointer: CGPoint?
    @State private var hovered: Int?
    @State private var dragging: Int?
    @State private var dragOffset = CGSize.zero
    @State private var reactions: [Int: Date] = [:]
    @State private var returns: [Int: Release] = [:]

    struct Release {
        var offset: CGSize
        var date: Date
    }
    /// Everything a frame of the running scene is drawn from.
    struct SceneState {
        var start = Date()
        var lead = 0.0
        /// Motion is on (not reduced or switched off).
        var animated = true
        /// The clock runs: the window is in front and nothing lies over the page.
        var live = true
        var background = false
        /// The moment the scene is held at, while it is held.
        var fixed: Double?
        var palette: HarborTheme.Palette
        /// Names the palette, to know when the cards have to be drawn again.
        var paletteKey = ""
        var pictures: [Int: NSImage] = [:]
        var pointer: CGPoint?
        var hovered: Int?
        var dragging: Int?
        var dragOffset = CGSize.zero
        var reactions: [Int: Date] = [:]
        var returns: [Int: Release] = [:]
    }

    struct Interaction {
        var pointer: CGPoint? = nil
        var hovered: Int? = nil
        var dragging: Int? = nil
        var dragOffset: CGSize = .zero
        var ages: [Int: Double] = [:]
        var releases: [Int: (offset: CGSize, age: Double)] = [:]
        var reducedMotion = false
    }

    static func dollCenter(_ index: Int, size: CGSize) -> CGPoint {
        let gap = size.width < 560 ? 8.0 : 14.0
        let width = (size.width - gap * 3) / 4
        return CGPoint(x: Double(index) * (width + gap) + width / 2, y: size.height - 8)
    }

    static func constrainedDrag(_ offset: CGSize, index: Int, size: CGSize) -> CGSize {
        let center = dollCenter(index, size: size)
        return CGSize(width: min(max(offset.width, 25 - center.x), size.width - 25 - center.x),
                      // Up to the top of the scene: a carried doll is in front of the cards, so it can go over them.
                      height: min(0, max(offset.height, -max(0, size.height - 96))))
    }

    static func returnOffset(_ offset: CGSize, age: Double, reducedMotion: Bool) -> CGSize {
        guard !reducedMotion, age >= 0, age < 0.65 else { return .zero }
        let progress = min(1, age / 0.65)
        let remaining = pow(1 - progress, 3)
        return CGSize(width: offset.width * remaining, height: offset.height * remaining)
    }

    private func react(_ index: Int) { reactions[index] = Date() }
    /// A fixed time renders one frame; used by previews and tests.
    var frozenAt: Double?
    /// Seconds of the scene that have already passed when it appears.
    var lead = 0.0
    /// Something lies over the page (the organizer, Settings). The scene holds still until it is
    /// gone: drawn sixty times a second it takes a good part of the main thread, which whatever
    /// lies over it needs for its own scrolling.
    var covered = false

    static let agents = ["claude", "codex", "grok", "gemini"]
    static let cycle = 15.0
    /// The moment every card is typed, filled and moored.
    static let settled = 9.0

    static func sceneTime(elapsed: Double, animated: Bool, active: Bool, frozenAt: Double?) -> Double {
        if let frozenAt { return frozenAt }
        // A background window can be created while its timeline is paused at zero.
        // Keep its dolls visible even before it first becomes the active window.
        return animated && active ? max(0, elapsed) : settled
    }

    var body: some View {
        let level = HarborMotion.level(stored, reduceMotion: reduceMotion)
        let animated = level == .full && frozenAt == nil
        let palette = HarborTheme.palette(dark: colorScheme == .dark, selection: appearance)
        let pictures = Self.pictures([dollClaude, dollCodex, dollGrok, dollGemini])
        // The clock runs in the active window, and in one that has only just appeared.
        let live = (activeState != .inactive || (!everActive && !background) || Self.alwaysLive) && held == nil
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Group {
                    if let frozenAt {
                        // One fixed frame, for a preview or a test: drawn where it stands.
                        Canvas { context, size in
                            Self.draw(&context, size: size, time: frozenAt, palette: palette, pictures: pictures, interaction: Interaction(reducedMotion: true), repeats: false)
                        }
                    } else {
                        // The running scene is drawn by its own surface, sheet by sheet, off the page's tree of views.
                        AgentHarborSurface(state: SceneState(start: start, lead: lead, animated: animated, live: live, background: background && !Self.alwaysLive, fixed: held?.time,
                            palette: palette, paletteKey: appearance + (colorScheme == .dark ? "|dark" : "|light"), pictures: pictures,
                            pointer: pointer, hovered: hovered, dragging: dragging, dragOffset: dragOffset, reactions: reactions, returns: returns))
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(width: geometry.size.width, height: geometry.size.height)
                ForEach(0..<Self.agents.count, id: \.self) { index in
                    let center = Self.dollCenter(index, size: geometry.size)
                    let hitHeight = min(86.0, max(36, geometry.size.height - 104))
                    Button { react(index) } label: {
                        Color.clear.frame(width: 76, height: hitHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: center.x, y: center.y - hitHeight / 2)
                    .accessibilityLabel("Play with " + Self.agents[index].capitalized)
                    .accessibilityIdentifier("start-doll-" + Self.agents[index])
                    .accessibilityHint("Click to bounce, or drag and release")
                    .help("Click to play · Drag to pick up")
                    .onHover { inside in
                        if inside { hovered = index }
                        else if hovered == index { hovered = nil }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            dragging = index
                            returns[index] = nil
                            dragOffset = Self.constrainedDrag(value.translation, index: index, size: geometry.size)
                        }
                        .onEnded { _ in
                            returns[index] = Release(offset: dragOffset, date: Date())
                            dragging = nil
                            dragOffset = .zero
                            react(index)
                        })
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): pointer = location
                case .ended: pointer = nil; hovered = nil
                }
            }
            .onChange(of: activeState) { _, state in
                if state == .inactive { dragging = nil; dragOffset = .zero; hovered = nil; pointer = nil }
                else { everActive = true }
            }
            .onAppear { if activeState != .inactive { everActive = true }; hold(covered) }
            .onChange(of: covered) { _, covered in hold(covered) }
            .task {
                try? await Task.sleep(for: .seconds(0.6))
                if !everActive { background = true }
            }
        }
    }

    /// Stops the scene's clock where it is, or lets it run on from there as if no time had passed.
    private func hold(_ covered: Bool) {
        if covered {
            guard held == nil else { return }
            held = (max(0, Date().timeIntervalSince(start) + lead), Date())
            dragging = nil; dragOffset = .zero; hovered = nil; pointer = nil
        } else if let held {
            start = start.addingTimeInterval(Date().timeIntervalSince(held.since)); self.held = nil
        }
    }
    #if DEBUG
    /// The clock runs in a window that is not in front as well: for measuring what the scene costs.
    static var alwaysLive: Bool { UserDefaults.standard.bool(forKey: "HarborQADollsLive") }
    #else
    static let alwaysLive = false
    #endif

    /// How often the scene was drawn and how long that took, for measuring.
    nonisolated(unsafe) static var draws = 0, drawSeconds = 0.0
    static func dollKey(_ agent: String) -> String { "startDoll_" + agent }
    private static var loaded: [String: NSImage] = [:]
    /// The chosen pictures by doll index; a path that no longer loads falls back to the drawing.
    static func pictures(_ paths: [String]) -> [Int: NSImage] {
        var result: [Int: NSImage] = [:]
        for (index, path) in paths.enumerated() where !path.isEmpty {
            if let image = loaded[path] ?? NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 { loaded[path] = image; result[index] = image }
        }
        return result
    }

    private static func ease(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return 1 - pow(1 - x, 3)
    }

    /// 0 with eyes open, 1 fully closed; each doll blinks on its own rhythm.
    private static func blinkAmount(_ t: Double, index: Int) -> Double {
        let phase = (t + Double(index) * 0.83).truncatingRemainder(dividingBy: 3.4)
        return phase < 0.16 ? sin(phase / 0.16 * .pi) : 0
    }

    private static func rgb(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity)
    }

    /// Four soft dolls, one per agent, drawn standing on the origin (feet at
    /// y = 0, up is negative). They are Harbor's own characters, told apart by
    /// color and shape: an orange four-toed plush, a blue terminal-faced hooded
    /// robot, a grey plush rocket, and a fluffy rainbow monster with party poppers.
    /// `wave` swings the raised arm (radians), `look` moves the pupils (-1...1).
    private static func drawDoll(_ context: inout GraphicsContext, kind: Int, dark: Bool, blink: Double, wave: Double, look: Double, time t: Double) {
        let open = max(0.12, 1 - blink)
        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path { Path(ellipseIn: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)) }
        func smile(_ c: inout GraphicsContext, y: Double, width: Double, color: Color) {
            var path = Path(); path.move(to: CGPoint(x: -width / 2, y: y))
            path.addQuadCurve(to: CGPoint(x: width / 2, y: y), control: CGPoint(x: 0, y: y + width * 0.55))
            c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        let face = rgb(0x2A211C)
        switch kind % 4 {
        case 0:
            // P1: the orange cowboy plush, with four toes and stitched pixel eyes.
            let body = rgb(0xE88A4D), deep = rgb(0xCC6835), light = rgb(0xF5AC70)
            for (i, x) in [-10.5, -3.5, 3.5, 10.5].enumerated() {
                let toe = Path(roundedRect: CGRect(x: x - 3.2, y: -10, width: 6.4, height: 10 + (i % 2 == 0 ? 0 : 0.7)), cornerRadius: 3)
                context.fill(toe, with: .color(deep))
                context.fill(toe, with: .linearGradient(Gradient(colors: [body, deep]), startPoint: CGPoint(x: x - 2, y: -9), endPoint: CGPoint(x: x + 3, y: 1)))
            }
            for side in [-1.0, 1.0] {
                var hand = context
                hand.translateBy(x: side * 13, y: -17)
                hand.rotate(by: .radians(side > 0 ? -wave * 0.65 : -0.08))
                let shape = Path(roundedRect: CGRect(x: -4, y: -6, width: 8, height: 12), cornerRadius: 4)
                hand.fill(shape, with: .linearGradient(Gradient(colors: [light, body, deep]), startPoint: CGPoint(x: -3, y: -6), endPoint: CGPoint(x: 4, y: 7)))
            }
            let shape = Path(roundedRect: CGRect(x: -13.5, y: -32, width: 27, height: 27), cornerRadius: 6, style: .continuous)
            context.fill(shape, with: .linearGradient(Gradient(colors: [light, body, deep]), startPoint: CGPoint(x: -10, y: -33), endPoint: CGPoint(x: 13, y: -4)))
            context.stroke(shape, with: .color(rgb(0xB85C30, 0.35)), lineWidth: 0.45)
            // Stable small flecks suggest plush fabric without flickering between frames.
            var texture = context
            texture.clip(to: shape)
            for i in 0..<95 {
                let x = -13 + Double((i * 47) % 263) / 10
                let y = -31 + Double((i * 31) % 251) / 10
                texture.fill(oval(x, y, 0.35, 0.85), with: .color(rgb(i % 2 == 0 ? 0xFFF1D7 : 0xAA4D2A, 0.11)))
            }
            for side in [-1.0, 1.0] {
                var eye = context
                eye.translateBy(x: side * 5.8 + look * 0.35, y: -23)
                eye.scaleBy(x: 1, y: open)
                for rect in [CGRect(x: -1.5, y: -1.5, width: 3, height: 1.7), CGRect(x: -3, y: 0, width: 1.7, height: 2), CGRect(x: 1.3, y: 0, width: 1.7, height: 2)] {
                    eye.fill(Path(rect), with: .color(face))
                }
            }
            // The reference's soft brown cowboy hat: creased crown and upturned brim.
            var crown = Path()
            crown.move(to: CGPoint(x: -11, y: -31))
            crown.addCurve(to: CGPoint(x: -8, y: -40), control1: CGPoint(x: -11.5, y: -36), control2: CGPoint(x: -12, y: -43))
            crown.addQuadCurve(to: CGPoint(x: -2, y: -40.5), control: CGPoint(x: -5, y: -36))
            crown.addQuadCurve(to: CGPoint(x: 4, y: -43), control: CGPoint(x: 2, y: -46))
            crown.addQuadCurve(to: CGPoint(x: 11, y: -32), control: CGPoint(x: 11, y: -43))
            crown.closeSubpath()
            context.fill(crown, with: .linearGradient(Gradient(colors: [rgb(0xBA9277), rgb(0x977055), rgb(0x805B42)]), startPoint: CGPoint(x: -7, y: -44), endPoint: CGPoint(x: 10, y: -29)))
            context.stroke(crown, with: .color(rgb(0x745038, 0.55)), lineWidth: 0.5)
            var crease = Path()
            crease.move(to: CGPoint(x: -6, y: -39)); crease.addQuadCurve(to: CGPoint(x: 4, y: -41), control: CGPoint(x: 0, y: -36))
            context.stroke(crease, with: .color(rgb(0x79573F, 0.55)), style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
            var band = Path()
            band.move(to: CGPoint(x: -11, y: -32.5)); band.addQuadCurve(to: CGPoint(x: 11, y: -33), control: CGPoint(x: 0, y: -29))
            context.stroke(band, with: .color(rgb(0x775238)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            var brim = Path()
            brim.move(to: CGPoint(x: -18, y: -35))
            brim.addCurve(to: CGPoint(x: 0, y: -30), control1: CGPoint(x: -17, y: -29), control2: CGPoint(x: -7, y: -29))
            brim.addQuadCurve(to: CGPoint(x: 18, y: -33), control: CGPoint(x: 12, y: -29))
            brim.addCurve(to: CGPoint(x: 8, y: -27), control1: CGPoint(x: 20, y: -27), control2: CGPoint(x: 13, y: -26))
            brim.addCurve(to: CGPoint(x: -18, y: -35), control1: CGPoint(x: -3, y: -27), control2: CGPoint(x: -21, y: -28))
            brim.closeSubpath()
            context.fill(brim, with: .linearGradient(Gradient(colors: [rgb(0xBC9579), rgb(0x926A4D)]), startPoint: CGPoint(x: 0, y: -35), endPoint: CGPoint(x: 0, y: -26)))
            context.stroke(brim, with: .color(rgb(0x78523A, 0.7)), style: StrokeStyle(lineWidth: 0.65, lineJoin: .round))
        case 1:
            // P2: a blue scalloped hood, navy terminal face and tiny suited body.
            let body = rgb(0x6683ED), deep = rgb(0x3D59BE), edge = rgb(0x25336A)
            func outlined(_ c: inout GraphicsContext, _ path: Path, _ fill: Color, width: Double = 0.6) {
                c.fill(path, with: .color(fill))
                c.stroke(path, with: .color(edge), style: StrokeStyle(lineWidth: width, lineJoin: .round))
            }
            for x in [-6.5, 1.5] {
                outlined(&context, Path(roundedRect: CGRect(x: x, y: -5.8, width: 5, height: 6), cornerRadius: 1.5), deep)
            }
            for side in [-1.0, 1.0] {
                var hand = context
                hand.translateBy(x: side * 8, y: -10)
                hand.rotate(by: .radians(side > 0 ? -0.25 - wave : 0.25))
                outlined(&hand, Path(roundedRect: CGRect(x: -2.2, y: -2, width: 4.4, height: 8), cornerRadius: 2), body)
            }
            outlined(&context, Path(roundedRect: CGRect(x: -7.5, y: -13.5, width: 15, height: 10.5), cornerRadius: 3), body)
            context.fill(Path(roundedRect: CGRect(x: -5.8, y: -12.5, width: 11.6, height: 5.5), cornerRadius: 1.5), with: .color(rgb(0x849DF8)))
            // A single continuous hood silhouette avoids seams between the scallops.
            var hood = Path()
            hood.move(to: CGPoint(x: -8, y: -35))
            hood.addCurve(to: CGPoint(x: 1, y: -36), control1: CGPoint(x: -7, y: -40), control2: CGPoint(x: -1, y: -40))
            hood.addCurve(to: CGPoint(x: 10, y: -32), control1: CGPoint(x: 6, y: -38), control2: CGPoint(x: 10, y: -37))
            hood.addCurve(to: CGPoint(x: 14, y: -23), control1: CGPoint(x: 15, y: -31), control2: CGPoint(x: 16, y: -26))
            hood.addCurve(to: CGPoint(x: 9, y: -14), control1: CGPoint(x: 15, y: -18), control2: CGPoint(x: 13, y: -15))
            hood.addQuadCurve(to: CGPoint(x: -9, y: -14), control: CGPoint(x: 0, y: -11))
            hood.addCurve(to: CGPoint(x: -14, y: -23), control1: CGPoint(x: -13, y: -15), control2: CGPoint(x: -16, y: -18))
            hood.addCurve(to: CGPoint(x: -8, y: -35), control1: CGPoint(x: -17, y: -28), control2: CGPoint(x: -13, y: -33))
            hood.closeSubpath()
            context.fill(hood, with: .linearGradient(Gradient(colors: [rgb(0x91ADFF), body, deep]), startPoint: CGPoint(x: -4, y: -39), endPoint: CGPoint(x: 6, y: -12)))
            context.stroke(hood, with: .color(edge), style: StrokeStyle(lineWidth: 0.65, lineJoin: .round))
            let screen = Path(roundedRect: CGRect(x: -9.5, y: -30, width: 19, height: 14.5), cornerRadius: 4)
            outlined(&context, screen, rgb(0x101D4F), width: 0.8)
            context.stroke(Path(roundedRect: CGRect(x: -8.6, y: -29.2, width: 17.2, height: 12.9), cornerRadius: 3.2), with: .color(rgb(0x4560A6)), lineWidth: 0.4)
            var display = context
            display.translateBy(x: look * 0.35, y: -23)
            display.scaleBy(x: 1, y: max(0.2, open))
            var chevron = Path()
            chevron.move(to: CGPoint(x: -5, y: -2.4)); chevron.addLine(to: CGPoint(x: -2.8, y: -0.4)); chevron.addLine(to: CGPoint(x: -5, y: 1.7))
            display.stroke(chevron, with: .color(rgb(0xA6F0FF)), style: StrokeStyle(lineWidth: 1.35, lineCap: .square, lineJoin: .miter))
            display.fill(Path(CGRect(x: 1.5, y: 1.4, width: 4.1, height: 1.3)), with: .color(rgb(0xA6F0FF)))
            var badge = Path()
            badge.move(to: CGPoint(x: -1.3, y: -11.2)); badge.addLine(to: CGPoint(x: 0.6, y: -9.8)); badge.addLine(to: CGPoint(x: -1.3, y: -8.3))
            context.stroke(badge, with: .color(rgb(0xF0F7FF)), style: StrokeStyle(lineWidth: 1, lineCap: .square))
            context.fill(Path(CGRect(x: 2, y: -8.8, width: 2.3, height: 0.8)), with: .color(rgb(0xF0F7FF)))
        case 2:
            // A grey plush rocket: a rounded nose, satin fins, a dark shield across the belly with two
            // rivets, round stitched eyes over orange cheeks, and feet with red soles (its engines).
            let body = rgb(0xD8D4D6), light = rgb(0xEDEAEA), shade = rgb(0xADA8AE), edge = rgb(0x77727A, dark ? 0.35 : 0.6)
            let satin = [rgb(0xF4F4F6), rgb(0xB9BAC2), rgb(0xE2E3E8)]
            func fin(_ c: inout GraphicsContext, x: Double, y: Double, lean: Double, size: Double) {
                var f = c
                f.translateBy(x: x, y: y); f.rotate(by: .radians(lean))
                var path = Path(); path.move(to: CGPoint(x: -size * 0.42, y: 0))
                path.addQuadCurve(to: CGPoint(x: 0, y: -size), control: CGPoint(x: -size * 0.5, y: -size * 0.75))
                path.addQuadCurve(to: CGPoint(x: size * 0.42, y: 0), control: CGPoint(x: size * 0.42, y: -size * 0.6))
                path.closeSubpath()
                f.fill(path, with: .linearGradient(Gradient(colors: satin), startPoint: CGPoint(x: -size * 0.4, y: -size), endPoint: CGPoint(x: size * 0.4, y: 0)))
                f.stroke(path, with: .color(edge), style: StrokeStyle(lineWidth: 0.45, lineJoin: .round))
            }
            // The fin on the far side shows past the nose.
            fin(&context, x: 7.5, y: -33, lean: 0.75, size: 6)
            // Feet first, so the body sits on them; the soles glow a little, like engines idling.
            let glow = 0.82 + 0.18 * sin(t * 3.1)
            for x in [-7.0, 7.0] {
                context.fill(oval(x, -1.6, 9.4, 5.2), with: .color(rgb(0xE5544D, glow)))
                context.fill(oval(x, -3.1, 9.6, 5.4), with: .color(body))
                context.stroke(oval(x, -3.1, 9.6, 5.4), with: .color(edge), lineWidth: 0.4)
            }
            for side in [-1.0, 1.0] {
                var hand = context
                hand.translateBy(x: side * 12.2, y: -11.5)
                hand.rotate(by: .radians(side * 0.5 - (side > 0 ? wave : 0)))
                let shape = Path(roundedRect: CGRect(x: -2.9, y: -2.5, width: 5.8, height: 8.5), cornerRadius: 2.9)
                hand.fill(shape, with: .color(body)); hand.stroke(shape, with: .color(edge), lineWidth: 0.4)
            }
            var hull = Path()
            hull.move(to: CGPoint(x: 0, y: -41))
            hull.addCurve(to: CGPoint(x: 13.5, y: -13), control1: CGPoint(x: 7.5, y: -40), control2: CGPoint(x: 13.5, y: -27))
            hull.addCurve(to: CGPoint(x: 0, y: -2), control1: CGPoint(x: 13.5, y: -5.5), control2: CGPoint(x: 7, y: -2))
            hull.addCurve(to: CGPoint(x: -13.5, y: -13), control1: CGPoint(x: -7, y: -2), control2: CGPoint(x: -13.5, y: -5.5))
            hull.addCurve(to: CGPoint(x: 0, y: -41), control1: CGPoint(x: -13.5, y: -27), control2: CGPoint(x: -7.5, y: -40))
            hull.closeSubpath()
            context.fill(hull, with: .linearGradient(Gradient(colors: [light, body, shade]), startPoint: CGPoint(x: -8, y: -40), endPoint: CGPoint(x: 11, y: -2)))
            var inside = context
            inside.clip(to: hull)
            // Plush flecks, fixed in place.
            for i in 0..<70 {
                let x = -13 + Double((i * 53) % 263) / 10, y = -40 + Double((i * 37) % 371) / 10
                inside.fill(oval(x, y, 0.35, 0.8), with: .color(rgb(i % 2 == 0 ? 0xFFFFFF : 0x8E8990, 0.12)))
            }
            // The shield: dark across the belly, rising in the middle.
            var shield = Path()
            shield.move(to: CGPoint(x: -15, y: -9))
            shield.addQuadCurve(to: CGPoint(x: -4.5, y: -13.5), control: CGPoint(x: -9.5, y: -9.5))
            shield.addQuadCurve(to: CGPoint(x: 4.5, y: -13.5), control: CGPoint(x: 0, y: -15.5))
            shield.addQuadCurve(to: CGPoint(x: 15, y: -9), control: CGPoint(x: 9.5, y: -9.5))
            shield.addLine(to: CGPoint(x: 15, y: 0)); shield.addLine(to: CGPoint(x: -15, y: 0)); shield.closeSubpath()
            inside.fill(shield, with: .linearGradient(Gradient(colors: [rgb(0x77747B), rgb(0x57545B)]), startPoint: CGPoint(x: 0, y: -15), endPoint: CGPoint(x: 0, y: -2)))
            for x in [-4.6, 4.6] { inside.fill(oval(x, -9.2, 2.3, 2.3), with: .color(rgb(0xD9DADF))); inside.fill(oval(x - 0.3, -9.6, 0.9, 0.9), with: .color(rgb(0xFFFFFF, 0.9))) }
            // The seam where the nose is sewn on.
            var seam = Path(); seam.move(to: CGPoint(x: -12.2, y: -25)); seam.addQuadCurve(to: CGPoint(x: 12.2, y: -25), control: CGPoint(x: 0, y: -21.5))
            inside.stroke(seam, with: .color(rgb(0x8E8990, 0.55)), lineWidth: 0.5)
            context.stroke(hull, with: .color(edge), style: StrokeStyle(lineWidth: 0.5, lineJoin: .round))
            fin(&context, x: -9.2, y: -27, lean: -0.42, size: 7)
            fin(&context, x: 6.4, y: -26.2, lean: 0.3, size: 6.6)
            for side in [-1.0, 1.0] {
                context.fill(oval(side * 9.6, -15.6, 3.6, 3.6), with: .color(rgb(0xF0A03C)))
                var eye = context
                eye.translateBy(x: side * 5.6, y: -18.6); eye.scaleBy(x: 1, y: open)
                eye.fill(oval(0, 0, 7.4, 7.4), with: .color(rgb(0xFFFFFF)))
                eye.fill(oval(0, 0, 6.3, 6.3), with: .color(rgb(0x17151A)))
                eye.fill(oval(1.1 + look * 0.7, -1.3, 2.1, 2.1), with: .color(rgb(0xFFFFFF)))
                eye.fill(oval(-1.2 + look * 0.5, 1.2, 1, 1), with: .color(rgb(0xFFFFFF, 0.85)))
            }
            smile(&context, y: -17.2, width: 3.2, color: rgb(0x17151A))
        default:
            // A fluffy monster: blue at the top running down through green, yellow and orange to pink,
            // two small horns, eyes with a spark in them, a grin with two teeth, and a party popper in
            // each raised hand.
            let blue = rgb(0x7FB0F2), deepBlue = rgb(0x5E8FDD)
            let fur: [Color] = [rgb(0x86B6F4), rgb(0x7FB0F2), rgb(0x7CCFC4), rgb(0xA4D97C), rgb(0xF2D56A), rgb(0xF4A262), rgb(0xEF7F86)]
            let stripes: [UInt32] = [0xE8674A, 0xF2B441, 0x5BAE6A, 0x4E8FE8, 0x9A6FD6]
            /// A soft outline: an ellipse whose edge rises and falls a little, like tufts of fur.
            func fluffy(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, tufts: Int, depth: Double) -> Path {
                var path = Path()
                let steps = tufts * 6
                for step in 0...steps {
                    let angle = Double(step) / Double(steps) * 2 * .pi
                    let bump = 1 + depth * (0.5 + 0.5 * sin(angle * Double(tufts)))
                    let point = CGPoint(x: cx + cos(angle) * w / 2 * bump, y: cy + sin(angle) * h / 2 * bump)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath(); return path
            }
            func popper(_ c: inout GraphicsContext, lean: Double) {
                var p = c
                p.rotate(by: .radians(lean))
                var cone = Path(); cone.move(to: CGPoint(x: 0, y: 1)); cone.addLine(to: CGPoint(x: -3, y: -8)); cone.addLine(to: CGPoint(x: 3, y: -8)); cone.closeSubpath()
                var striped = p
                striped.clip(to: cone)
                for (index, stripe) in stripes.enumerated() {
                    striped.fill(Path(CGRect(x: -4, y: -8.1 + Double(index) * 1.85, width: 8, height: 2)), with: .color(rgb(stripe)))
                }
                p.fill(oval(0, -8, 6, 1.6), with: .color(rgb(0xF6E9C8)))
                // What has just come out of it.
                for (index, stripe) in stripes.enumerated() {
                    let angle = -1.95 + Double(index) * 0.42, reach = 3.2 + Double((index * 7) % 3) + sin(t * 2.4 + Double(index)) * 0.5
                    var curl = Path(); curl.move(to: CGPoint(x: cos(angle) * 1.3, y: -8.8))
                    curl.addQuadCurve(to: CGPoint(x: cos(angle) * reach, y: -8.8 + sin(angle) * reach), control: CGPoint(x: cos(angle) * reach * 0.2, y: -8.8 + sin(angle) * reach * 0.9))
                    p.stroke(curl, with: .color(rgb(stripe)), style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
                }
            }
            for x in [-6.5, 6.5] {
                context.fill(fluffy(x, -2.6, 8.6, 5.6, tufts: 7, depth: 0.1), with: .color(blue))
                for toe in [-1.6, 0.0, 1.6] { context.fill(oval(x + toe, -0.9, 1.1, 1.3), with: .color(rgb(0x4A4650))) }
            }
            for side in [-1.0, 1.0] {
                var hand = context
                hand.translateBy(x: side * 12.6, y: -17.5)
                hand.rotate(by: .radians(side * 0.8 - (side > 0 ? wave * 0.7 : 0)))
                let sleeve = fluffy(0, -3, 6.8, 10.5, tufts: 9, depth: 0.09)
                hand.fill(sleeve, with: .linearGradient(Gradient(colors: [rgb(0xEF7F86), rgb(0xF4A262), rgb(0xA4D97C), blue]), startPoint: CGPoint(x: 0, y: -8.5), endPoint: CGPoint(x: 0, y: 2.5)))
                hand.translateBy(x: 0, y: -6.5)
                popper(&hand, lean: -side * 0.5)
            }
            for side in [-1.0, 1.0] {
                // Short and thick, bowed outwards, with two ridges.
                var horn = Path(); horn.move(to: CGPoint(x: side * 11.4, y: -24.5))
                horn.addQuadCurve(to: CGPoint(x: side * 9.8, y: -36.6), control: CGPoint(x: side * 15, y: -32.5))
                horn.addQuadCurve(to: CGPoint(x: side * 6.2, y: -28.5), control: CGPoint(x: side * 8.8, y: -31.5))
                horn.closeSubpath()
                context.fill(horn, with: .linearGradient(Gradient(colors: [rgb(0x9CC2F6), deepBlue]), startPoint: CGPoint(x: side * 7, y: -38), endPoint: CGPoint(x: side * 12, y: -26)))
                var ridged = context
                ridged.clip(to: horn)
                for y in [-30.2, -33.4] {
                    var ridge = Path(); ridge.move(to: CGPoint(x: side * 6, y: y + 1.2)); ridge.addQuadCurve(to: CGPoint(x: side * 15, y: y), control: CGPoint(x: side * 10.5, y: y - 1.2))
                    ridged.stroke(ridge, with: .color(rgb(0x4673C4, 0.55)), lineWidth: 0.55)
                }
            }
            let coat = fluffy(0, -16.2, 29, 28.5, tufts: 22, depth: 0.035)
            // Blue for the upper half, then the bands.
            let stops: [Gradient.Stop] = zip(fur, [0, 0.46, 0.58, 0.69, 0.79, 0.89, 1]).map { Gradient.Stop(color: $0, location: $1) }
            context.fill(coat, with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: 0, y: -31), endPoint: CGPoint(x: 0, y: -2)))
            var strands = context
            strands.clip(to: coat)
            for i in 0..<110 {
                let x = -14 + Double((i * 47) % 281) / 10, y = -30 + Double((i * 31) % 283) / 10
                strands.fill(oval(x, y, 0.35, 1.5), with: .color(rgb(i % 2 == 0 ? 0xFFFFFF : 0x3F5F9E, 0.13)))
            }
            for side in [-1.0, 1.0] {
var brow = Path(); brow.move(to: CGPoint(x: side * 2.8, y: -27.8)); brow.addQuadCurve(to: CGPoint(x: side * 9, y: -27.2), control: CGPoint(x: side * 6, y: -29.8))
                context.stroke(brow, with: .color(deepBlue), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                var eye = context
                eye.translateBy(x: side * 5.7, y: -21.8); eye.scaleBy(x: 1, y: open)
                eye.fill(oval(0, 0, 8.6, 8.6), with: .color(rgb(0xFFFFFF)))
                let iris = oval(look * 0.9, 0.1, 6.2, 6.2)
                eye.fill(iris, with: .conicGradient(Gradient(colors: (stripes + [stripes[0]]).map { rgb($0) }), center: CGPoint(x: look * 0.9, y: 0.1), angle: .radians(t * 0.6)))
                eye.fill(oval(look * 0.9, 0.1, 4.1, 4.1), with: .color(rgb(0x1D1B26)))
                // The spark: four points, the long ones up and down.
                var spark = Path()
                let cx = look * 0.9, cy = 0.1
                spark.move(to: CGPoint(x: cx, y: cy - 2.3)); spark.addQuadCurve(to: CGPoint(x: cx + 1.7, y: cy), control: CGPoint(x: cx + 0.25, y: cy - 0.25))
                spark.addQuadCurve(to: CGPoint(x: cx, y: cy + 2.3), control: CGPoint(x: cx + 0.25, y: cy + 0.25))
                spark.addQuadCurve(to: CGPoint(x: cx - 1.7, y: cy), control: CGPoint(x: cx - 0.25, y: cy + 0.25))
                spark.addQuadCurve(to: CGPoint(x: cx, y: cy - 2.3), control: CGPoint(x: cx - 0.25, y: cy - 0.25))
                eye.fill(spark, with: .color(rgb(0xFFFFFF)))
            }
            // The grin: open, with a tongue and a small tooth at each corner.
            var mouth = Path(); mouth.move(to: CGPoint(x: -5.2, y: -14.6))
            mouth.addQuadCurve(to: CGPoint(x: 5.2, y: -14.6), control: CGPoint(x: 0, y: -13.2))
            mouth.addQuadCurve(to: CGPoint(x: -5.2, y: -14.6), control: CGPoint(x: 0, y: -6.4))
            mouth.closeSubpath()
            context.fill(mouth, with: .color(rgb(0x3A2025)))
            var inner = context
            inner.clip(to: mouth)
            inner.fill(oval(0, -9.6, 6, 3.6), with: .color(rgb(0xF08A94)))
            for side in [-1.0, 1.0] {
                var tooth = Path(); tooth.move(to: CGPoint(x: side * 3.9, y: -14.4)); tooth.addLine(to: CGPoint(x: side * 2.1, y: -14)); tooth.addLine(to: CGPoint(x: side * 3, y: -12)); tooth.closeSubpath()
                inner.fill(tooth, with: .color(rgb(0xFFFFFF)))
            }
        }
    }

    #if DEBUG
    /// The four dolls side by side and enlarged, to look at them closely.
    static func dollSheet(dark: Bool, scale: Double, blink: Double = 0, wave: Double = 0, look: Double = 0, time: Double = 0) -> some View {
        Canvas { context, size in
            for kind in 0..<4 {
                var doll = context
                doll.translateBy(x: (Double(kind) + 0.5) * size.width / 4, y: size.height - 6 * scale)
                doll.scaleBy(x: scale, y: scale)
                drawDoll(&doll, kind: kind, dark: dark, blink: blink, wave: wave, look: look, time: time)
            }
        }.frame(width: 4 * 46 * scale, height: 56 * scale)
    }
    #endif

    /// What one pass draws. The scene is three sheets, bottom to top: the cards, the lines of work
    /// on the cards, and the quay with the dolls. Once the cards have settled only the dolls move
    /// (and the lines glow, slowly), so each sheet is drawn only as often as it changes.
    struct Parts: OptionSet {
        let rawValue: Int
        static let dolls = Parts(rawValue: 1), cards = Parts(rawValue: 2), lines = Parts(rawValue: 4)
        static let all: Parts = [.dolls, .cards, .lines]
    }
    /// From here on the cards are as they stay: the last one has typed its command and its light is on.
    static let cardsSettled = 0.5 + Double(agents.count - 1) * 0.85 + 2.9

    static func draw(_ context: inout GraphicsContext, size: CGSize, time t: Double, palette: HarborTheme.Palette, pictures: [Int: NSImage] = [:], interaction: Interaction = Interaction(), repeats: Bool = true, parts: Parts = .all) {
        func color(_ role: String) -> Color { Color(nsColor: HarborTheme.hex(palette.colors[role] ?? "#808080")) }
        let ink = color("foreground"), muted = color("descriptionForeground"), line = color("panel.border")
        let surface = color("editorWidget.background"), accent = color("focusBorder")
        // Each card takes its doll's color: orange, blue, the page's ink for the grey rocket, and violet for the rainbow one.
        let tints = [rgb(0xD97757), rgb(0x4A86E8), ink, rgb(0x9A6FD6)]
        // The whole scene fades out before the loop restarts.
        context.opacity = repeats ? 1 - ease((t - (cycle - 0.9)) / 0.9) : 1

        let count = Double(agents.count), gap = size.width < 560 ? 8.0 : 14.0
        // Cards share the full width so the row aligns with the page's columns.
        let cardWidth = (size.width - gap * (count - 1)) / count, cardHeight = 96.0
        let rowWidth = size.width
        let originX = 0.0, top = 4.0
        let quayY = size.height - 8
        let dollScale = min(1.8, max(0.9, (quayY - top - cardHeight - 6) / 40))
        let dark = HarborTheme.hex(palette.colors["editor.background"] ?? "#FFFFFF").brightnessComponent < 0.5

        // Quay: a hairline that draws from the leading edge.
        let quay = ease((t - 0.15) / 1.1)
        var quayPath = Path()
        quayPath.move(to: CGPoint(x: originX, y: quayY))
        quayPath.addLine(to: CGPoint(x: originX + rowWidth * quay, y: quayY))
        if parts.contains(.dolls) { context.stroke(quayPath, with: .color(line), lineWidth: 1) }

        func carried(_ index: Int) -> Bool { interaction.dragging == index || (interaction.releases[index].map { $0.age < 0.65 } ?? false) }
        // Two rounds. First the cards with their lines, and behind each card the doll that is still
        // dropping in under it. Then the dolls that have landed, in front of everything: a doll that
        // hops, is played with or is carried upward is never cut off by a card. The one being
        // carried comes last, in front of the others.
        for round in 0..<2 {
        let order = round == 0 ? Array(agents.indices) : agents.indices.sorted { carried($0) != carried($1) ? !carried($0) : $0 < $1 }
        for index in order {
            let name = agents[index]
            let begin = 0.5 + Double(index) * 0.85
            let appear = ease((t - begin) / 0.6)
            guard appear > 0 else { continue }
            let tint = tints[index % tints.count]
            let x = originX + Double(index) * (cardWidth + gap), y = top + (1 - appear) * 12
            let card = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
            var layer = context
            layer.opacity = context.opacity * appear

            // Each agent has a doll that drops onto the quay under its card, waves once it has
            // landed, then breathes, blinks, glances around and hops now and then.
            let landing = begin + 1.7
            let arrive = ease((t - landing) / 0.55)
            if arrive > 0, parts.contains(.dolls), (round == 1) == (arrive >= 1) {
                let since = max(0, t - landing - 0.55)
                // A short squash after touching down, then slow breathing.
                let squash = arrive >= 1 ? exp(-6 * since) * sin(18 * since) * 0.14 : 0
                let breath = sin(t * 2.2 + Double(index) * 1.1) * 0.03
                let period = 5.2, beat = (t + Double(index) * 1.3).truncatingRemainder(dividingBy: period)
                let hop = arrive >= 1 && since > 1.4 && beat < 0.5 ? sin(beat / 0.5 * .pi) * 7 : 0
                let selected = interaction.hovered == index
                let held = interaction.dragging == index
                let age = interaction.ages[index] ?? 100
                let bounce = !interaction.reducedMotion && age >= 0 && age < 0.65 ? sin(age / 0.65 * .pi) * 21 : 0
                var offset = held ? interaction.dragOffset : CGSize.zero
                if !held, let release = interaction.releases[index] {
                    offset = returnOffset(release.offset, age: release.age, reducedMotion: interaction.reducedMotion)
                }
                let lift = (1 - arrive) * 46 + hop + bounce + (selected && !interaction.reducedMotion ? 3 : 0) - offset.height
                let ground = CGPoint(x: card.midX + offset.width, y: quayY)
                if selected || held || (interaction.reducedMotion && age < 0.9) {
                    context.fill(Path(ellipseIn: CGRect(x: ground.x - 22, y: ground.y - 5, width: 44, height: 9)), with: .color(tint.opacity(0.14)))
                    context.stroke(Path(ellipseIn: CGRect(x: ground.x - 22, y: ground.y - 5, width: 44, height: 9)), with: .color(tint.opacity(0.5)), lineWidth: 1)
                }
                if age >= 0 && age < 0.9 && !interaction.reducedMotion {
                    let progress = age / 0.9
                    for particle in 0..<9 {
                        let angle = Double(particle) / 9 * .pi * 2
                        let radius = 9 + progress * 28
                        let point = CGPoint(x: ground.x + cos(angle) * radius,
                                            y: ground.y - 24 * dollScale + sin(angle) * radius * 0.6 - progress * 12)
                        var spark = Path()
                        let r = 2.6 * (1 - progress) + 0.4
                        spark.move(to: CGPoint(x: point.x - r, y: point.y)); spark.addLine(to: CGPoint(x: point.x + r, y: point.y))
                        spark.move(to: CGPoint(x: point.x, y: point.y - r)); spark.addLine(to: CGPoint(x: point.x, y: point.y + r))
                        context.stroke(spark, with: .color(tint.opacity(1 - progress)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    }
                }
                let shadow = 1 - min(1, lift / 46)
                context.fill(Path(ellipseIn: CGRect(x: ground.x - 13 * shadow, y: ground.y - 1.5, width: 26 * shadow, height: 4)), with: .color(ink.opacity(0.10 * shadow)))
                var doll = context
                doll.opacity = context.opacity * min(1, arrive * 2)
                doll.translateBy(x: ground.x, y: ground.y - lift)
                if held && !interaction.reducedMotion { doll.rotate(by: .degrees(max(-12, min(12, offset.width * 0.12)))) }
                let greeting = selected && !interaction.reducedMotion ? 0.06 : 0
                doll.scaleBy(x: dollScale * (1 + squash - breath * 0.6 + greeting), y: dollScale * (1 - squash + breath + greeting))
                let wave = since < 1.4 && arrive >= 1 ? sin(since * 13) * 0.55 * (1 - since / 1.4) + 0.5 * (1 - since / 1.4) : 0
                let look = interaction.pointer.map { max(-1, min(1, ($0.x - ground.x) / 65)) } ?? sin(t * 0.7 + Double(index) * 2.1)
                let greetingWave = selected && !interaction.reducedMotion ? sin(t * 9) * 0.3 + 0.35 : 0
                if let picture = pictures[index] {
                    // The user's own picture stands where the doll would, about as tall, and moves the same way.
                    let height = 38.0, width = min(64, height * picture.size.width / picture.size.height)
                    doll.draw(Image(nsImage: picture).interpolation(.high), in: CGRect(x: -width / 2, y: -height, width: width, height: height))
                } else {
                    drawDoll(&doll, kind: index, dark: dark, blink: blinkAmount(t, index: index), wave: wave + greetingWave, look: look, time: t)
                }
            }

            guard round == 0 else { continue }
            if parts.contains(.cards) {
            let shape = Path(roundedRect: card, cornerRadius: 10, style: .continuous)
            layer.fill(shape, with: .color(surface))
            layer.stroke(shape, with: .color(line), lineWidth: 1)

            // Status light: neutral while starting, the agent's tint once ready.
            let ready = ease((t - begin - 1.9) / 0.4)
            let dot = CGRect(x: card.minX + 12, y: card.minY + 13, width: 6, height: 6)
            layer.fill(Path(ellipseIn: dot), with: .color(muted.opacity(0.45 * (1 - ready))))
            layer.fill(Path(ellipseIn: dot), with: .color(tint.opacity(ready)))
            let pulse = (t - begin - 1.9) / 0.9
            if pulse > 0 && pulse < 1 {
                let spread = 7 * ease(pulse)
                layer.stroke(Path(ellipseIn: dot.insetBy(dx: -spread, dy: -spread)), with: .color(tint.opacity(0.55 * (1 - pulse))), lineWidth: 1)
            }

            // Prompt: the command types itself, followed by a blinking caret.
            let typed = Int((ease((t - begin - 0.45) / 0.55) * Double(name.count)).rounded(.down))
            let fontSize = cardWidth < 130 ? 11.0 : 13.0
            let prompt = layer.resolve(Text(verbatim: "›").font(.system(size: fontSize, weight: .semibold, design: .monospaced)).foregroundColor(tint))
            let baseline = CGPoint(x: card.minX + 12, y: card.minY + 40)
            layer.draw(prompt, at: baseline, anchor: .leading)
            let command = layer.resolve(Text(verbatim: String(name.prefix(typed))).font(.system(size: fontSize, weight: .medium, design: .monospaced)).foregroundColor(ink))
            let commandX = baseline.x + prompt.measure(in: size).width + 6
            layer.draw(command, at: CGPoint(x: commandX, y: baseline.y), anchor: .leading)
            let caretVisible = t < begin + 1.9 && (typed < name.count || Int((t - begin) * 2.4) % 2 == 0)
            if caretVisible {
                let caretX = commandX + (typed > 0 ? command.measure(in: size).width : 0) + 1
                layer.fill(Path(CGRect(x: caretX, y: baseline.y - fontSize * 0.55, width: 1.5, height: fontSize * 1.1)), with: .color(accent))
            }
            }

            // Output: three lines of work filling in, then a slow highlight.
            guard parts.contains(.lines) else { continue }
            let inner = cardWidth - 24
            for (row, fraction) in [0.84, 0.56, 0.7].enumerated() {
                let grow = ease((t - begin - 1.1 - Double(row) * 0.16) / 0.5)
                guard grow > 0 else { continue }
                let bar = CGRect(x: card.minX + 12, y: card.minY + 58 + Double(row) * 11, width: inner * fraction * grow, height: 5)
                let shimmer = 0.5 + 0.5 * sin((t - begin) * 1.1 - Double(row) * 0.9)
                let fill = row == 0 ? tint.opacity(0.30 + 0.18 * shimmer) : ink.opacity(0.08 + 0.05 * shimmer)
                layer.fill(Path(roundedRect: bar, cornerRadius: 2.5), with: .color(fill))
            }
        }
        }
    }
}

/// The running scene's surface: a plain view with three sheets, each a layer holding a picture.
///
/// Drawn in a Canvas on a timeline, every frame went through SwiftUI's whole update of the page:
/// its tree brought up to date, laid out and gone through again to be shown, sixty times a second,
/// whatever little had changed. Here a frame is drawn straight into a picture and handed to a
/// layer, and the page is not involved. And each sheet is drawn only as often as it changes: the
/// dolls every frame, the lines of work on the cards (a slow glow) a few times a second, and the
/// cards with their text once, after they have settled. Laid over one another the sheets are the
/// scene drawn in one pass, which a test holds them to.
struct AgentHarborSurface: NSViewRepresentable {
    let state: AgentHarborAnimation.SceneState
    func makeNSView(context: Context) -> SceneView { let view = SceneView(); view.state = state; return view }
    func updateNSView(_ view: SceneView, context: Context) { view.state = state; view.stateChanged() }

    final class SceneView: NSView {
        var state = AgentHarborAnimation.SceneState(palette: HarborTheme.palette(dark: false, selection: HarborTheme.selection))
        private let dolls = CALayer(), cards = CALayer(), lines = CALayer()
        private var link: CADisplayLink?
        /// What the cards' picture was drawn for: its size, the screen's scale and the palette.
        private var cardsKey = ""
        private var frames = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            let root = CALayer(); layer = root; wantsLayer = true
            for sheet in [cards, lines, dolls] {
                // A picture is put in place as it is, without a fade from the one before.
                sheet.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
                sheet.contentsGravity = .resize
                root.addSublayer(sheet)
            }
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        deinit { link?.invalidate() }
        // The dolls are played with through the buttons that lie over them.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for sheet in [dolls, cards, lines] { sheet.frame = bounds }
            CATransaction.commit()
            render()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { surfaces = [:]; for sheet in [dolls, cards, lines] { sheet.contents = nil } }
            stateChanged()
        }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); cardsKey = ""; render() }

        private var running: Bool { state.animated && state.live && window != nil }
        /// The clock is started or stopped as the state says, and what there is to see is drawn.
        func stateChanged() {
            if running {
                if link == nil {
                    let link = displayLink(target: self, selector: #selector(step(_:)))
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                    link.add(to: .main, forMode: .common)
                    self.link = link
                }
            } else { link?.invalidate(); link = nil }
            render()
        }
        @objc private func step(_ link: CADisplayLink) { MainActor.assumeIsolated { render() } }

        /// One renderer for each kind of pass, kept between frames.
        private var renderers: [Int: ImageRenderer<AnyView>] = [:]
        private func renderer(_ parts: AgentHarborAnimation.Parts, time: Double, interaction: AgentHarborAnimation.Interaction, scale: CGFloat) -> ImageRenderer<AnyView> {
            let state = self.state
            let content = AnyView(Canvas { context, size in
                AgentHarborAnimation.draw(&context, size: size, time: time, palette: state.palette, pictures: state.pictures, interaction: interaction, repeats: false, parts: parts)
            }.frame(width: bounds.width, height: bounds.height))
            let renderer: ImageRenderer<AnyView>
            if let kept = renderers[parts.rawValue] { renderer = kept; renderer.content = content } else { renderer = ImageRenderer(content: content); renderers[parts.rawValue] = renderer }
            if renderer.scale != scale { renderer.scale = scale }
            return renderer
        }
        /// A picture of its own, for the cards: drawn once, after they have settled.
        private func picture(_ parts: AgentHarborAnimation.Parts, time: Double, interaction: AgentHarborAnimation.Interaction, scale: CGFloat) -> CGImage? {
            renderer(parts, time: time, interaction: interaction, scale: scale).cgImage
        }

        /// The sheets drawn every frame or so are drawn into surfaces the window server reads as they
        /// are. A new picture each frame was drawn on the graphics card, copied back, and copied
        /// again into a new surface for the server, sixty times a second; when the server fell
        /// behind, the whole window waited for it. Now a frame draws into a surface that is not on
        /// screen, and when none is free the frame is left out rather than waited for.
        private final class SheetSurfaces {
            private var surfaces: [IOSurfaceRef] = []
            private var width = 0, height = 0
            /// Surfaces could not be made; the sheet is drawn as a picture instead.
            private(set) var unavailable = false
            func next(width: Int, height: Int, current: Any?) -> IOSurfaceRef? {
                if width != self.width || height != self.height || surfaces.isEmpty {
                    self.width = width; self.height = height
                    surfaces = (0..<3).compactMap { _ in Self.make(width: width, height: height) }
                    unavailable = surfaces.count < 2
                }
                let shown = current as AnyObject?
                return surfaces.first { !IOSurfaceIsInUse($0) && ($0 as AnyObject) !== shown }
            }
            private static func make(width: Int, height: Int) -> IOSurfaceRef? {
                let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                                   kIOSurfacePixelFormat: UInt32(0x42475241)] // 'BGRA'
                guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
                // Tagged sRGB, as the pictures were, so the dolls keep their colors on a wide-gamut screen.
                if let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() { IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, space) }
                return surface
            }
        }
        private var surfaces: [Int: SheetSurfaces] = [:]
        /// Draws one sheet onto its layer.
        private func draw(_ parts: AgentHarborAnimation.Parts, on sheet: CALayer, time: Double, interaction: AgentHarborAnimation.Interaction, scale: CGFloat) {
            let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
            guard width > 0, height > 0 else { return }
            let pool = surfaces[parts.rawValue] ?? SheetSurfaces()
            surfaces[parts.rawValue] = pool
            let surface = pool.next(width: width, height: height, current: sheet.contents)
            if pool.unavailable { sheet.contents = picture(parts, time: time, interaction: interaction, scale: scale); return }
            // Every surface is still on screen: the server is behind, and this frame is left out.
            guard let surface else { return }
            IOSurfaceLock(surface, [], nil)
            defer { IOSurfaceUnlock(surface, [], nil) }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: IOSurfaceGetBaseAddress(surface), width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            renderer(parts, time: time, interaction: interaction, scale: scale).render(rasterizationScale: scale) { _, draw in draw(context) }
            sheet.contents = surface
        }
        /// One frame. Nothing is drawn for a scene that is out of sight.
        func render() {
            guard let window, bounds.width > 1, bounds.height > 1, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
            let began = CFAbsoluteTimeGetCurrent()
            let scale = window.backingScaleFactor, now = Date(), state = self.state
            let time = AgentHarborAnimation.sceneTime(elapsed: now.timeIntervalSince(state.start) + state.lead, animated: state.animated && !state.background,
                                                      active: state.live, frozenAt: state.fixed)
            let interaction = AgentHarborAnimation.Interaction(pointer: state.pointer, hovered: state.hovered, dragging: state.dragging, dragOffset: state.dragOffset,
                ages: state.reactions.mapValues { max(0, now.timeIntervalSince($0)) },
                releases: state.returns.mapValues { ($0.offset, max(0, now.timeIntervalSince($0.date))) }, reducedMotion: !state.animated)
            // Until the cards have settled (and the last doll has dropped in behind its card) the scene is one picture.
            let sheets = running && time >= AgentHarborAnimation.cardsSettled
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if sheets {
                let key = "\(bounds.width)x\(bounds.height)@\(scale)|" + state.paletteKey
                if key != cardsKey || cards.contents == nil {
                    cards.contents = picture(.cards, time: time, interaction: interaction, scale: scale); cardsKey = key; frames = 0
                }
                // The glow on the lines takes seconds to come and go: a quarter of the frames show all of it.
                if frames % 4 == 0 || lines.contents == nil { draw(.lines, on: lines, time: time, interaction: interaction, scale: scale) }
                draw(.dolls, on: dolls, time: time, interaction: interaction, scale: scale)
                cards.isHidden = false; lines.isHidden = false; frames += 1
            } else {
                draw(.all, on: dolls, time: time, interaction: interaction, scale: scale)
                cards.isHidden = true; lines.isHidden = true
                if cards.contents != nil { cards.contents = nil; lines.contents = nil; cardsKey = "" }
            }
            for sheet in [dolls, cards, lines] where sheet.contentsScale != scale { sheet.contentsScale = scale }
            CATransaction.commit()
            AgentHarborAnimation.draws += 1; AgentHarborAnimation.drawSeconds += CFAbsoluteTimeGetCurrent() - began
        }
    }
}

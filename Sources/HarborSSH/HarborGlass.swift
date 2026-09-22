import SwiftUI

/// Native interpretation of liquid-glass-react's refractive surface, directional
/// edge light and elastic hover. See docs/LIQUID-GLASS.md. Text is a separate layer;
/// terminal/editor surfaces never become glass or get captured into a texture.
private struct HarborGlassAppearance: ViewModifier {
    var radius: Double = 9
    var tint: Color = .harborAccent
    var prominent = false
    var elevated = false
    var light = UnitPoint(x: 0.25, y: 0)
    var highlighted = false
    var fallback: Color = .harborWidget
    @AppStorage("liquidGlassEnabled") private var enabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var translucent: Bool { enabled && !reduceTransparency && contrast != .increased }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    func body(content: Content) -> some View {
        surface(content: content)
            .overlay {
                if translucent {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.28 : 0.75),
                            tint.opacity(highlighted ? 0.42 : 0.14), .white.opacity(0.04)],
                            startPoint: light, endPoint: UnitPoint(x: 1 - light.x, y: 1)), lineWidth: 0.7)
                    if highlighted {
                        shape.fill(RadialGradient(colors: [.white.opacity(scheme == .dark ? 0.12 : 0.25), .clear],
                            center: light, startRadius: 0, endRadius: 70))
                    }
                } else {
                    shape.strokeBorder(Color.harborBorder, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(translucent && elevated ? (scheme == .dark ? 0.28 : 0.12) : 0), radius: 12, y: 4)
    }
    @ViewBuilder private func surface(content: Content) -> some View {
        if translucent {
            if #available(macOS 26, *) {
                // The system owns refraction/compositing; there is no WebView,
                // snapshot loop or custom GPU buffer for decorative effects.
                content.glassEffect(.regular.tint(tint.opacity(prominent ? 0.85 : 0.10)), in: shape)
            } else {
                content.background { shape.fill(.regularMaterial).overlay { shape.fill(tint.opacity(prominent ? 0.85 : 0.08)) }.allowsHitTesting(false) }
            }
        } else { content.background { shape.fill(prominent ? Color.harborButton : fallback).allowsHitTesting(false) } }
    }
}

/// Decorative-only background used beneath a persistent row or tab. The button
/// itself stays outside the conditional material branch, preserving list focus.
struct HarborGlassSurface: View {
    var radius: Double = 9
    var tint: Color = .harborAccent
    var fallback: Color = .harborWidget
    var body: some View {
        Color.clear.modifier(HarborGlassAppearance(radius: radius, tint: tint, fallback: fallback))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func harborGlass(radius: Double = 9, tint: Color = .harborAccent, elevated: Bool = false,
                     fallback: Color = .harborWidget) -> some View {
        modifier(HarborGlassAppearance(radius: radius, tint: tint, elevated: elevated, fallback: fallback))
    }
    func harborSelectionGlass(_ selected: Bool, radius: Double = 8,
                              inactive: Color = .clear, active: Color = .harborSelection) -> some View {
        background {
            if selected { HarborGlassSurface(radius: radius, tint: .harborAccent, fallback: active) }
            else { RoundedRectangle(cornerRadius: radius).fill(inactive) }
        }
    }
}

/// Batch nearby small surfaces through one compositor. Spacing stays below the
/// normal toolbar gap, so distinct buttons do not blur into one ambiguous target.
struct HarborGlassCluster<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 6, content: content) }
        else { content() }
    }
}

struct HarborGlassButtonStyle: ButtonStyle {
    var prominent = false
    var radius: Double = 9
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, radius: radius)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let radius: Double
    @AppStorage("liquidGlassEnabled") private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var point = CGPoint.zero
    @State private var size = CGSize(width: 30, height: 30)
    private var dx: Double { min(max((point.x / max(size.width, 1) - 0.5) * 2, -1), 1) }
    private var dy: Double { min(max((point.y / max(size.height, 1) - 0.5) * 2, -1), 1) }
    private var moving: Bool { enabled && isEnabled && !reduceMotion && hovered }
    var body: some View {
        configuration.label
            .modifier(HarborGlassAppearance(radius: radius, prominent: prominent,
                light: UnitPoint(x: moving ? (dx + 1) / 2 : 0.25, y: moving ? (dy + 1) / 2 : 0),
                highlighted: hovered && isEnabled))
            .scaleEffect(x: configuration.isPressed && moving ? 0.96 : moving ? 1.025 + abs(dx) * 0.025 : 1,
                         y: configuration.isPressed && moving ? 0.96 : moving ? 1.025 + abs(dy) * 0.025 : 1)
            .offset(x: moving ? dx * 1.5 : 0, y: moving ? dy * 1.5 : 0)
            .animation(reduceMotion || !enabled ? nil : .spring(response: 0.28, dampingFraction: 0.68), value: hovered)
            .animation(reduceMotion || !enabled ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
            .animation(reduceMotion || !enabled ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.86), value: point)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { size = geometry.size }.onChange(of: geometry.size) { _, value in size = value }
                }.allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = true; if enabled && !reduceMotion { point = location }
                case .ended: hovered = false
                }
            }
            .onDisappear { hovered = false }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

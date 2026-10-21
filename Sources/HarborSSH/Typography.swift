import SwiftUI
import AppKit

enum HarborTypography {
    static func value(_ key: String, fallback: Double = 13, range: ClosedRange<Double> = 9...32) -> Double {
        let n = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        return n.isFinite ? min(max(n, range.lowerBound), range.upperBound) : fallback
    }
}
/// The interface text scale and whether display type is serif. Each window reads the two
/// preferences once and hands them down: nearly every piece of text uses `harborFont`, and a
/// preference observer inside each one made large views such as Settings slow to build.
struct HarborTypeStyle: Equatable {
    var scale = 1.0
    var serif = false
    init(size: Double, appearance: String) { scale = min(max(size, 11), 20) / 13; serif = HarborTheme.isAnthropic(appearance) }
    /// What the preferences say now, for views outside a window that hands the style down.
    static var stored: HarborTypeStyle { HarborTypeStyle(size: HarborTypography.value("interfaceFontSize", range: 11...20), appearance: HarborTheme.selection) }
}
private struct HarborTypeStyleKey: EnvironmentKey { static var defaultValue: HarborTypeStyle { .stored } }
extension EnvironmentValues {
    var harborTypeStyle: HarborTypeStyle {
        get { self[HarborTypeStyleKey.self] }
        set { self[HarborTypeStyleKey.self] = newValue }
    }
}
private struct HarborFont: ViewModifier {
    @Environment(\.harborTypeStyle) private var style
    var base: Double
    var weight: Font.Weight
    var design: Font.Design
    func body(content: Content) -> some View {
        // Anthropic pairs serif display type with a plain sans for controls.
        content.font(.system(size: base * style.scale, weight: weight, design: style.serif && design == .rounded ? .serif : design))
    }
}
private struct HarborTypeRoot: ViewModifier {
    @AppStorage("interfaceFontSize") private var size = 13.0
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    func body(content: Content) -> some View { content.environment(\.harborTypeStyle, HarborTypeStyle(size: size, appearance: appearance)) }
}
extension View {
    func harborFont(_ size: Double = 13, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(HarborFont(base: size, weight: weight, design: design))
    }
    /// Put at the root of a window's content: text below follows the interface size and theme as they change.
    func harborTypography() -> some View { modifier(HarborTypeRoot()) }
}
enum AppResources {
    static func directory(_ name: String) -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HarborSSH_HarborSSH.bundle/" + name)
        }
        return Bundle.module.bundleURL.appendingPathComponent(name)
    }
}

import SwiftUI
import AppKit

enum HarborTypography {
    static func value(_ key: String, fallback: Double = 13, range: ClosedRange<Double> = 9...32) -> Double {
        let n = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        return n.isFinite ? min(max(n, range.lowerBound), range.upperBound) : fallback
    }
}
private struct HarborFont: ViewModifier {
    @AppStorage("interfaceFontSize") private var size = 13.0
    var base: Double
    var weight: Font.Weight
    var design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: base * min(max(size, 11), 20) / 13, weight: weight, design: design))
    }
}
extension View {
    func harborFont(_ size: Double = 13, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(HarborFont(base: size, weight: weight, design: design))
    }
}
enum AppResources {
    static func directory(_ name: String) -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HarborSSH_HarborSSH.bundle/" + name)
        }
        return Bundle.module.bundleURL.appendingPathComponent(name)
    }
}

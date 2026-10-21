import SwiftUI
import AppKit

/// The shadow of a panel that lies over the window (Folders in Windows, Settings, the Option+Tab
/// list): a layer that is given the panel's outline and casts its shadow from that.
///
/// SwiftUI's .shadow on the panel's shape left the shadow to be worked out again from the shape
/// itself each time that part of the window was put together, which is every frame while a list
/// on the panel scrolls: a blur the size of the panel, done outside Harbor (a sample of Harbor
/// found it idle while the list moved at ten frames a second). From a given outline the shadow
/// is drawn directly.
struct HarborPanelShadow: NSViewRepresentable {
    var cornerRadius: CGFloat
    var radius: CGFloat
    var opacity: Double
    /// Room around the panel for the shadow to spread into, kept inside this view's own bounds.
    static func margin(_ radius: CGFloat) -> CGFloat { ceil(radius * 2) }
    func makeNSView(context: Context) -> ShadowView { ShadowView() }
    func updateNSView(_ view: ShadowView, context: Context) {
        view.cornerRadius = cornerRadius; view.radius = radius; view.opacity = opacity
        view.needsLayout = true
    }

    final class ShadowView: NSView {
        var cornerRadius: CGFloat = 12, radius: CGFloat = 24, opacity = 0.3
        /// The layer that casts the shadow. The view's own layer is Harbor's (it hosts it), so
        /// nothing of AppKit's sets its shadow back.
        let caster = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            let root = CALayer(); layer = root; wantsLayer = true
            root.masksToBounds = false
            caster.actions = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull(), "shadowOpacity": NSNull(), "shadowRadius": NSNull()]
            caster.shadowColor = NSColor.black.cgColor
            caster.shadowOffset = .zero
            root.addSublayer(caster)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        // Nothing here takes the pointer.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
        override func layout() {
            super.layout()
            let margin = HarborPanelShadow.margin(radius)
            let outline = bounds.insetBy(dx: margin, dy: margin)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            caster.frame = bounds
            caster.shadowRadius = radius
            if outline.width > 0, outline.height > 0 {
                let corner = min(cornerRadius, outline.width / 2, outline.height / 2)
                caster.shadowPath = CGPath(roundedRect: outline, cornerWidth: corner, cornerHeight: corner, transform: nil)
                caster.shadowOpacity = Float(opacity)
            } else {
                caster.shadowPath = nil; caster.shadowOpacity = 0
            }
            CATransaction.commit()
        }
    }
}

extension View {
    /// A panel's ground: its fill, and the shadow it casts on the window under it, `y` points
    /// lower than the panel.
    func harborPanelGround(_ fill: Color, cornerRadius: CGFloat, shadow opacity: Double, radius: CGFloat, y: CGFloat) -> some View {
        background {
            ZStack {
                HarborPanelShadow(cornerRadius: cornerRadius, radius: radius, opacity: opacity)
                    .padding(-HarborPanelShadow.margin(radius)).offset(y: y)
                    .allowsHitTesting(false).accessibilityHidden(true)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill)
            }
        }
    }
}

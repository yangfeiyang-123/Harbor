import SwiftUI

/// Static symbols keep controls quiet and predictable, including on hover.
struct HarborSymbol: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .frame(width: 18, height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(systemName).accessibilityIdentifier(systemName)
    }
}

enum HarborLayout {
    static func reveal(_ value: Double, from lower: Double, to upper: Double) -> Double {
        let t = min(max((value - lower) / (upper - lower), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
struct RevealingLabel<Content: View>: View {
    var amount: Double
    @ViewBuilder var content: Content
    var body: some View { RevealLayout(amount: amount) { content.fixedSize(horizontal: true, vertical: false) }.clipped().opacity(amount).accessibilityHidden(amount < 0.05) }
}
private struct RevealLayout: Layout {
    var amount: Double
    var animatableData: Double { get { amount } set { amount = newValue } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.width * amount, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

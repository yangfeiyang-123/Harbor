import SwiftUI

/// Recompute text reveals and native child bounds from the presented width on
/// every frame, instead of snapping content to the destination before resizing.
struct InterpolatedWidth<Content: View>: View, Animatable {
    var width: Double
    @ViewBuilder var content: (Double) -> Content
    var animatableData: Double { get { width } set { width = newValue } }
    var body: some View { content(width).transaction { $0.animation = nil } }
}

struct ExplorerActionLayout: Layout {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    private var travel: Double { sin(min(max(progress, 0), 1) * .pi / 2) }
    private var rise: Double { 1 - cos(min(max(progress, 0), 1) * .pi / 2) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: 50 + 52 * travel, height: 54 - 28 * rise)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, view) in subviews.enumerated() {
            let bottom = index >= 2
            let x = Double(index % 2) * 26 + (bottom ? 52 * travel : 0)
            let y = bottom ? 28 * (1 - rise) : 0
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(width: 24, height: 26))
        }
    }
}

/// Keep the directory picker reachable at icon width, then bring the actions
/// onto its row as space opens up. The two hit areas never overlap in transit.
struct ExplorerHeaderLayout: Layout {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    private var actionY: Double { 30 * (1 - min(max(progress, 0), 1)) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let actions = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? 195, height: max(26, actionY + actions.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let actions = subviews[1].sizeThatFits(.unspecified)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: max(24, bounds.width - actions.width - 4), height: 26))
        subviews[1].place(at: CGPoint(x: bounds.maxX - actions.width, y: bounds.minY + actionY), anchor: .topLeading,
            proposal: ProposedViewSize(actions))
    }
}

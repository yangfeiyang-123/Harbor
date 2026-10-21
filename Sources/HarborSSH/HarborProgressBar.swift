import SwiftUI

/// Progress as one thin line that fills from nothing to all of it, so a wait shows how far
/// along it is and when it will be over. Nothing spins, and nothing cycles. The amount is
/// measured where it can be (`value`), paced by how long the step took before (`pace`), and
/// otherwise by how long this kind of wait usually takes (`expected`).
struct HarborProgressBar: View {
    /// 0...1, where the amount is known.
    var value: Double?
    var pace: Pace?
    /// Seconds such a wait usually takes, when there is neither a measure nor a pace.
    var expected = 2.0
    var width = 160.0
    var height = 3.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var stored = HarborMotion.Level.full.rawValue
    @State private var appeared = Date()

    /// One stretch of a wait: from one amount to another, in about `expected` seconds.
    struct Pace: Equatable {
        var from: Double
        var to: Double
        var began: Date
        var expected: Double
        func value(at now: Date) -> Double {
            from + (to - from) * HarborProgressBar.estimate(now.timeIntervalSince(began) / max(expected, 0.05))
        }
        static func fixed(_ amount: Double) -> Pace { Pace(from: amount, to: amount, began: Date(), expected: 1) }
    }
    /// The share of a stretch that is shown as done after `x` of its expected time: steady up to
    /// nine tenths when the time is up, then ever slower, so the line only completes when the step does.
    static func estimate(_ x: Double) -> Double {
        x < 1 ? 0.9 * max(0, x) : 0.9 + 0.1 * (1 - exp(-(x - 1) * 1.2))
    }

    var body: some View {
        let level = HarborMotion.level(stored, reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: level == .full ? 1.0 / 30 : 0.5, paused: value != nil)) { timeline in
            let amount = value ?? pace?.value(at: timeline.date) ?? 0.97 * Self.estimate(timeline.date.timeIntervalSince(appeared) / max(expected, 0.05))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.harborForeground.opacity(0.14))
                Capsule().fill(Color.harborForeground.opacity(0.82))
                    .frame(width: max(height, width * min(max(amount, 0), 1)))
                    // Measured amounts arrive in steps; the line moves between them.
                    .animation(level == .off ? nil : .easeOut(duration: 0.3), value: amount)
            }
            .frame(width: width, height: height).clipShape(Capsule())
            .accessibilityElement().accessibilityLabel("Progress")
            .accessibilityValue("\(Int((min(max(amount, 0), 1) * 100).rounded())) percent")
        }
        .frame(width: width, height: height)
    }
}

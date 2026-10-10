import SwiftUI

// The motion vocabulary every view draws from. Timing lives in `AetherVisual`
// next to the rest of the design tokens; this file holds the reusable pieces
// that apply it, so a value tick, a press or a disclosure moves the same way
// on every page. Each respects Reduce Motion: the state still changes, only
// the travel is dropped.

extension AetherVisual {
    /// Press and hover feedback: short enough to feel instant.
    static let pressFeedback = Animation.easeOut(duration: 0.12)
    /// A number ticking to its next value (traffic, counts, latency).
    static let valueChange = Animation.spring(response: 0.36, dampingFraction: 0.9)
    /// A disclosure opening or closing.
    static let disclosure = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// A switch knob travelling to its other side.
    static let switchToggle = Animation.spring(response: 0.3, dampingFraction: 0.72)
    /// The one repeating attention cue: the menu bar's "new version" badge.
    static let attentionPulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    /// A row or inline message arriving in, or leaving, a list.
    @MainActor static var insertion: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        )
    }
}

/// A borderless button whose content dips slightly while pressed. Use it for
/// card-like buttons (node cards, list rows, the outlet summary) that draw
/// their own background and would otherwise give no press feedback.
struct AetherPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .opacity(pressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : AetherVisual.pressFeedback, value: pressed)
    }
}

extension ButtonStyle where Self == AetherPressableButtonStyle {
    static var aetherPressable: AetherPressableButtonStyle { AetherPressableButtonStyle() }
}

private struct AetherNumericValueModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    let countsDown: Bool

    func body(content: Content) -> some View {
        content
            .contentTransition(.numericText(countsDown: countsDown))
            .animation(reduceMotion ? nil : AetherVisual.valueChange, value: value)
    }
}

extension View {
    /// Rolls the digits of a changing number instead of swapping the text.
    /// Pair it with `.monospacedDigit()` so the width does not jitter.
    ///
    /// Only for numbers that change because something happened (a count, a
    /// result). Never for a value that ticks on its own: every frame of the
    /// roll draws the digits blurred, scaled and offset, Core Graphics caches
    /// each of those renderings, and a once-a-second rate filled its glyph
    /// cache to about 90 MB that is never returned (1.5.1). Use
    /// `aetherLiveValue()` for those.
    func aetherNumericValue<Value: Equatable>(_ value: Value, countsDown: Bool = false) -> some View {
        modifier(AetherNumericValueModifier(value: value, countsDown: countsDown))
    }

    /// A value that updates on its own (rates, live totals): the text is
    /// swapped in place with no transition, so each update draws the digits
    /// once at rest. `.monospacedDigit()` keeps the width steady.
    func aetherLiveValue() -> some View {
        contentTransition(.identity)
    }
}

/// The chevron of a custom disclosure. It turns rather than swapping symbols,
/// so the eye can follow the section opening.
struct AetherDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : AetherVisual.disclosure, value: isExpanded)
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

/// A copy button that confirms the copy in place: its symbol turns into a
/// check mark for a moment, then turns back. `action` returns whether the
/// copy happened, so a failure never shows the check mark.
struct AetherCopyButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: Text
    var systemImage = "doc.on.doc"
    let action: () -> Bool

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard action() else { return }
            didCopy = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Label {
                title
            } icon: {
                Image(systemName: didCopy ? "checkmark" : systemImage)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    // Only the confirmation is tinted; otherwise the icon
                    // inherits the button's style, including its disabled dim.
                    .foregroundStyle(didCopy ? AnyShapeStyle(Color.green) : AnyShapeStyle(ForegroundStyle()))
            }
        }
        .animation(reduceMotion ? nil : AetherVisual.quickFade, value: didCopy)
        .onDisappear { resetTask?.cancel() }
    }
}

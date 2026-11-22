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
            .scaleEffect(pressed && !reduceMotion && !AetherVisual.isReduceMotionForced ? 0.985 : 1)
            .opacity(pressed ? 0.82 : 1)
            .animation(AetherVisual.animation(AetherVisual.pressFeedback, reduceMotion: reduceMotion), value: pressed)
    }
}

extension ButtonStyle where Self == AetherPressableButtonStyle {
    static var aetherPressable: AetherPressableButtonStyle { AetherPressableButtonStyle() }
}

private struct AetherAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(
            AetherVisual.animation(animation, reduceMotion: reduceMotion),
            value: value
        )
    }
}

private struct AetherNumericValueModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let countsDown: Bool

    func body(content: Content) -> some View {
        // CoreGraphics caches a distinct interpolated variable-font CGFont in
        // CGFontCacheGetLocalCache.local_font_cache for every intermediate
        // animation frame of .numericText and never evicts it (~15.6 MB/hour on
        // sidebar ConnectionCountBadge and latency badges). Swap digits in
        // place with .identity while keeping .monospacedDigit() at call sites.
        content
            .contentTransition(.identity)
    }
}

extension View {
    /// Applies `animation` while reactively respecting SwiftUI's
    /// `accessibilityReduceMotion` environment as well as the UI review override.
    func aetherAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(AetherAnimationModifier(animation: animation, value: value))
    }

    /// Marks an event-driven numeric value (counts, measured results) so
    /// updates swap cleanly in place via `.contentTransition(.identity)` without
    /// interpolating variable-font frames into CoreGraphics's glyph cache.
    /// Pair it with `.monospacedDigit()` so width does not jitter, and use
    /// `aetherLiveValue()` for self-ticking metrics.
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
            .animation(AetherVisual.animation(AetherVisual.disclosure, reduceMotion: reduceMotion), value: isExpanded)
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
    var copiedTitle: Text? = nil
    let action: () -> Bool

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        let shouldReduceMotion = reduceMotion || AetherVisual.isReduceMotionForced
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
                if didCopy, let copiedTitle {
                    copiedTitle
                        .foregroundStyle(AetherReadableTint(color: .green))
                } else {
                    title
                }
            } icon: {
                Image(systemName: didCopy ? "checkmark" : systemImage)
                    .contentTransition(shouldReduceMotion ? .identity : .symbolEffect(.replace))
                    // Only the confirmation is tinted; otherwise the icon
                    // inherits the button's style, including its disabled dim.
                    .foregroundStyle(didCopy ? AnyShapeStyle(AetherReadableTint(color: .green)) : AnyShapeStyle(ForegroundStyle()))
            }
        }
        .animation(AetherVisual.animation(AetherVisual.quickFade, reduceMotion: reduceMotion), value: didCopy)
        .onDisappear { resetTask?.cancel() }
    }
}

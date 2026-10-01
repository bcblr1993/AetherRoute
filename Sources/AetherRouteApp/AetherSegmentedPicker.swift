import AppKit
import SwiftUI

/// A native segmented control that marks its selection the same way as the
/// Overview's routing and engine controls: accent fill plus the status dot.
/// SwiftUI's segmented Picker cannot carry the dot, so every text-only
/// segmented choice uses this instead. `.disabled` and `.controlSize` apply
/// through the environment, as they do for a Picker.
struct AetherSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    struct Option {
        let value: Value
        let title: String
    }

    /// Read here so a window gaining or losing key status updates the
    /// selection dot to match the fill AppKit draws.
    @Environment(\.controlActiveState) private var controlActiveState
    @Binding var selection: Value
    let options: [Option]
    var accessibilityLabel: String? = nil
    var accessibilityIdentifier: String? = nil
    var fillsWidth = false

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, options: options)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        configure(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.options = options
        configure(control, context: context)
    }

    /// The control's size from the segment widths set in `configure`; a
    /// full-width control takes whatever width it is offered.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView control: NSSegmentedControl,
        context: Context
    ) -> CGSize? {
        let height = control.intrinsicContentSize.height
        guard fillsWidth else {
            // The sum of the widths set in `configure`. The control's own
            // intrinsic width lags a width change until the next layout.
            let width = (0..<control.segmentCount).reduce(CGFloat.zero) {
                $0 + control.width(forSegment: $1)
            }
            return CGSize(width: width, height: height)
        }
        let natural = control.intrinsicContentSize.width
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: natural, height: height)
        }
        return CGSize(width: max(width, natural), height: height)
    }

    private func configure(_ control: NSSegmentedControl, context: Context) {
        if control.segmentCount != options.count {
            control.segmentCount = options.count
        }
        for (index, option) in options.enumerated()
        where control.label(forSegment: index) != option.title {
            control.setLabel(option.title, forSegment: index)
        }
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        control.isEnabled = context.environment.isEnabled
        control.markSelectedSegment(onAccentFill: controlActiveState == .key)
        control.controlSize = switch context.environment.controlSize {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
        // Equal segments, sized up front. `.fillEqually` widens the segments
        // only after the first layout pass, so the width SwiftUI measured
        // first was wrong and a narrow DNS page overflowed its window. Every
        // segment also reserves room for the selection dot, so moving the
        // selection never changes the control's width.
        // A full-width control is sized by its container, so AppKit can
        // share that width out equally without the first-pass problem.
        control.segmentDistribution = fillsWidth ? .fillEqually : .fit
        let segmentWidth = fillsWidth
            ? 0
            : context.coordinator.segmentWidth(
                for: options.map(\.title),
                controlSize: control.controlSize
            )
        for index in 0..<options.count
        where control.width(forSegment: index) != segmentWidth {
            control.setWidth(segmentWidth, forSegment: index)
        }
        control.selectedSegmentBezelColor = .controlAccentColor
        control.setContentHuggingPriority(
            fillsWidth ? .defaultLow : .required,
            for: .horizontal
        )
        if let accessibilityIdentifier {
            control.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        if let accessibilityLabel {
            control.setAccessibilityLabel(accessibilityLabel)
        }
    }

    /// The width AppKit itself gives the widest label once it carries the
    /// selection dot, measured on a one-segment control of the same size.
    @MainActor
    static func measureSegmentWidth(
        for titles: [String],
        controlSize: NSControl.ControlSize
    ) -> CGFloat {
        // One probe per title: relabelling a probe does not refresh its
        // intrinsic width, which then stayed at the first label's size.
        titles.map { title in
            let probe = NSSegmentedControl(
                labels: [title],
                trackingMode: .selectOne,
                target: nil,
                action: nil
            )
            probe.controlSize = controlSize
            probe.segmentDistribution = .fit
            probe.selectedSegment = 0
            probe.markSelectedSegment()
            return probe.intrinsicContentSize.width
        }.max().map(ceil) ?? 0
    }

    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [Option]
        /// Labels such as "All 12" refresh with live counts; measure only
        /// when the text or size actually changes.
        private var measuredKey: ([String], NSControl.ControlSize)?
        private var measuredWidth: CGFloat = 0

        @MainActor
        func segmentWidth(
            for titles: [String],
            controlSize: NSControl.ControlSize
        ) -> CGFloat {
            if let measuredKey, measuredKey.0 == titles, measuredKey.1 == controlSize {
                return measuredWidth
            }
            measuredWidth = AetherSegmentedPicker.measureSegmentWidth(
                for: titles,
                controlSize: controlSize
            )
            measuredKey = (titles, controlSize)
            return measuredWidth
        }

        init(selection: Binding<Value>, options: [Option]) {
            self.selection = selection
            self.options = options
        }

        @MainActor @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard options.indices.contains(sender.selectedSegment) else { return }
            sender.markSelectedSegment(onAccentFill: sender.window?.isKeyWindow == true)
            selection.wrappedValue = options[sender.selectedSegment].value
        }
    }
}

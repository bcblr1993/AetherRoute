import AppKit
import SwiftUI

/// The compact filter uses AppKit's popup so its menu retains native actions.
/// Wide layouts continue to use the existing segmented SwiftUI picker.
struct NativeFilterPicker<Selection: Hashable>: NSViewRepresentable {
    @Binding var selection: Selection
    let options: [Selection]
    let title: (Selection) -> String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NativeFilterPopUpButton {
        NativeFilterPopUpButton(frame: .zero, pullsDown: false)
    }

    func updateNSView(_ button: NativeFilterPopUpButton, context: Context) {
        let binding = $selection
        let values = options
        button.configure(.init(
            identities: values.map { AnyHashable($0) },
            titles: values.map(title),
            selectedIndex: { values.firstIndex(of: binding.wrappedValue) },
            selectIndex: { index in
                guard values.indices.contains(index) else { return }
                binding.wrappedValue = values[index]
            },
            label: accessibilityLabel,
            identifier: accessibilityIdentifier,
            isEnabled: isEnabled
        ))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeFilterPopUpButton,
        context: Context
    ) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        let width = proposal.width.map { min(max(0, $0), ideal.width) } ?? ideal.width
        return CGSize(width: width, height: ideal.height)
    }
}

@MainActor
final class NativeFilterPopUpButton: NSPopUpButton, NSMenuDelegate {
    struct Configuration {
        let identities: [AnyHashable]
        let titles: [String]
        let selectedIndex: @MainActor () -> Int?
        let selectIndex: @MainActor (Int) -> Void
        let label: String
        let identifier: String
        let isEnabled: Bool
    }

    private var configuration: Configuration?
    private var pendingConfiguration: Configuration?
    private var displayedIdentities: [AnyHashable] = []
    private var displayedTitles: [String] = []
    private var menuIsTracking = false
    private var menuIsClosing = false

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        target = self
        action = #selector(selectionChanged(_:))
        font = .systemFont(ofSize: NSFont.systemFontSize)
        cell?.lineBreakMode = .byTruncatingTail
        menu?.delegate = self
        menu?.autoenablesItems = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ next: Configuration) {
        // Telemetry can change option counts while the user navigates a menu.
        // Keep its current rows, mapping and focus until AppKit finishes tracking.
        if menuIsTracking || menuIsClosing {
            pendingConfiguration = next
        } else {
            apply(next)
        }
    }

    private func apply(_ next: Configuration) {
        configuration = next
        if next.identities != displayedIdentities || next.titles != displayedTitles {
            removeAllItems()
            addItems(withTitles: next.titles)
            displayedIdentities = next.identities
            displayedTitles = next.titles
            for (item, title) in zip(itemArray, next.titles) { item.toolTip = title }
            menu?.delegate = self
            menu?.autoenablesItems = false
            invalidateIntrinsicContentSize()
        }
        selectItem(at: next.selectedIndex() ?? -1)
        isEnabled = next.isEnabled && !next.identities.isEmpty
        setAccessibilityLabel(next.label)
        setAccessibilityIdentifier(next.identifier)
        toolTip = selectedItem?.title
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        guard displayedIdentities.indices.contains(sender.indexOfSelectedItem) else { return }
        configuration?.selectIndex(sender.indexOfSelectedItem)
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsTracking = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsTracking = false
        menuIsClosing = true
        // AppKit delivers the selection action as tracking ends. Apply deferred
        // rows on the next loop turn and read the binding then, never a stale index.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuIsClosing = false
            guard !self.menuIsTracking, let pending = self.pendingConfiguration else { return }
            self.pendingConfiguration = nil
            self.apply(pending)
        }
    }
}

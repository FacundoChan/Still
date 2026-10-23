import AppKit
import SwiftUI

/// A pop-up menu whose items show a detail right-aligned in a second column, such as "High    99.5 Mbit/s".
///
/// SwiftUI menus can't do this: their item titles drop paragraph styles, so a tab falls back to the default tab
/// stops and the details don't line up. This is AppKit's pull-down button with attributed item titles instead.
struct ColumnMenu<Value: Hashable>: NSViewRepresentable {
    struct Item {
        let value: Value
        let title: String
        let detail: String
        var isEnabled = true
    }

    /// What the button shows.
    let title: String
    let items: [Item]
    let selection: Value?
    let choose: (Value) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.chosen(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let values = items.map(\.value)
        context.coordinator.choose = { index in choose(values[index]) }

        // SwiftUI updates often, also while the menu is open; rebuilding it then would lose the click.
        let contents = [title] + items.map { "\($0.title)|\($0.detail)|\($0.isEnabled)|\($0.value == selection)" }
        guard contents != context.coordinator.contents else { return }
        context.coordinator.contents = contents

        button.removeAllItems()
        // A pull-down button shows its first item as its face and lists the rest.
        button.addItem(withTitle: title)
        button.item(at: 0)?.tag = -1

        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let titleColumn = items.map { width($0.title) }.max() ?? 0
        let detailColumn = items.map { width($0.detail) }.max() ?? 0
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titleColumn + 28 + detailColumn))]

        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let text = NSMutableAttributedString(string: "\(item.title)\t\(item.detail)",
                                                 attributes: [.font: font, .paragraphStyle: style])
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                              range: NSRange(location: item.title.utf16.count + 1, length: item.detail.utf16.count))
            menuItem.attributedTitle = text
            menuItem.state = item.value == selection ? .on : .off
            menuItem.isEnabled = item.isEnabled
            menuItem.tag = index
            // VoiceOver reads the title and detail as one phrase.
            menuItem.setAccessibilityLabel("\(item.title), \(item.detail)")
            button.menu?.addItem(menuItem)
        }
    }

    final class Coordinator: NSObject {
        var choose: ((Int) -> Void)?
        /// What the menu was last built from.
        var contents: [String] = []

        @objc func chosen(_ sender: NSPopUpButton) {
            guard let tag = sender.selectedItem?.tag, tag >= 0 else { return }
            choose?(tag)
        }
    }
}

import AppKit
import SwiftUI

/// Connects an editor to the window SwiftUI hosts it in: sheets, the unsaved-edits dot in the close button,
/// and confirmation before closing.
struct EditorWindowBridge: NSViewRepresentable {
    let model: EditorModel
    let isEdited: Bool

    func makeNSView(context: Context) -> BridgeView {
        BridgeView(model: model)
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.isEdited = isEdited
        view.connect()
    }

    final class BridgeView: NSView {
        private let model: EditorModel
        private var closeGuard: WindowCloseGuard?

        var isEdited = false {
            didSet { window?.isDocumentEdited = isEdited }
        }

        init(model: EditorModel) {
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        func connect() {
            guard let window else { return }
            model.window = window
            window.isDocumentEdited = isEdited
            // SwiftUI may replace the delegate as the scene updates; step back in front of whatever it set.
            if window.delegate !== closeGuard {
                closeGuard = WindowCloseGuard(window: window, model: model)
            }
        }
    }
}

/// Asks the editor before its window closes.
///
/// SwiftUI owns the window’s delegate, so the guard stands in front of it and forwards every other message.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var model: EditorModel?
    /// The delegate SwiftUI installed. Read from `responds(to:)` and `forwardingTarget(for:)`, which AppKit
    /// calls on the main thread.
    nonisolated(unsafe) private weak var forwardee: (any NSWindowDelegate)?
    private var isAsking = false
    private var isConfirmed = false

    init(window: NSWindow, model: EditorModel) {
        self.model = model
        forwardee = window.delegate
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isConfirmed, let model, model.needsCloseConfirmation {
            if !isAsking {
                isAsking = true
                Task {
                    let close = await model.confirmClose(quitting: false)
                    isAsking = false
                    guard close else { return }
                    isConfirmed = true
                    sender.performClose(nil)
                    isConfirmed = false
                }
            }
            return false
        }
        return forwardee?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        // The window has already asked. Leave the coordinator now, before AppKit checks whether this was the
        // last window and quits, so quitting doesn't ask again.
        if let model { WindowCoordinator.shared.unregister(model) }
        forwardee?.windowWillClose?(notification)
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardee?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let forwardee, forwardee.responds(to: selector) { return forwardee }
        return super.forwardingTarget(for: selector)
    }
}

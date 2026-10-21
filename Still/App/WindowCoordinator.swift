import AppKit
import Observation
import SwiftUI

/// Identifies an editor window and what it should do when it first appears.
struct EditorWindowRequest: Codable, Hashable {
    enum Action: String, Codable {
        case openFile
        case presentOpenPanel
        case presentPhotosPicker
    }

    var id = UUID()
    var action: Action
}

/// Routes videos to windows: the active window takes a video while it is still empty; otherwise the video
/// opens in a new window (goal.md §5, “Import sources”).
///
/// Window values must be Codable, so the security-scoped URLs themselves wait here until their window appears.
@Observable
final class WindowCoordinator {
    static let shared = WindowCoordinator()

    @ObservationIgnored private var pendingFiles: [UUID: URL] = [:]
    @ObservationIgnored private var queuedExternalFiles: [URL] = []
    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private weak var activeEditor: EditorModel?
    @ObservationIgnored private var editors: [WeakEditor] = []

    private struct WeakEditor {
        weak var editor: EditorModel?
    }

    /// Editors whose windows are open, front to back as they were registered.
    private var openEditors: [EditorModel] {
        editors.compactMap(\.editor)
    }

    func register(_ editor: EditorModel, openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        editors.removeAll { $0.editor == nil || $0.editor === editor }
        editors.append(WeakEditor(editor: editor))
        if activeEditor == nil { activeEditor = editor }
        let queued = queuedExternalFiles
        queuedExternalFiles.removeAll()
        for url in queued { open(url, preferring: editor) }
    }

    /// The menu bar's openWindow, for when files arrive or a menu command runs before any window has appeared.
    func provide(_ openWindow: OpenWindowAction) {
        guard self.openWindow == nil else { return }
        self.openWindow = openWindow
        let queued = queuedExternalFiles
        queuedExternalFiles.removeAll()
        guard !queued.isEmpty else { return }
        // Not while the menu bar is updating.
        Task { for url in queued { open(url, preferring: activeEditor) } }
    }

    func unregister(_ editor: EditorModel) {
        editors.removeAll { $0.editor == nil || $0.editor === editor }
        if activeEditor === editor { activeEditor = openEditors.last }
    }

    func activate(_ editor: EditorModel) {
        activeEditor = editor
    }

    /// Opens `url` in `editor` if it is empty, otherwise in a new window.
    func open(_ url: URL, preferring editor: EditorModel?) {
        if let editor, editor.isEmpty {
            Task { await editor.load(url) }
            return
        }
        let request = EditorWindowRequest(action: .openFile)
        pendingFiles[request.id] = url
        openWindow?(value: request)
    }

    /// Opens a new window that immediately shows the file panel or the Photos picker.
    func openNewWindow(_ action: EditorWindowRequest.Action) {
        openWindow?(value: EditorWindowRequest(action: action))
    }

    /// Carries out a window’s request once it has appeared.
    func handle(_ request: EditorWindowRequest?, in editor: EditorModel) {
        guard let request else { return }
        switch request.action {
        case .openFile:
            if let url = pendingFiles.removeValue(forKey: request.id) {
                Task { await editor.load(url) }
            }
        case .presentOpenPanel:
            editor.isImporterPresented = true
        case .presentPhotosPicker:
            editor.isPhotosPickerPresented = true
        }
    }

    /// Files from Finder’s Open With or the Dock icon. At launch they can arrive before any window exists.
    func openExternal(_ urls: [URL]) {
        guard openWindow != nil else {
            queuedExternalFiles += urls
            return
        }
        for url in urls { open(url, preferring: activeEditor) }
    }

    // MARK: - Quitting (goal.md §5, “Windows”)

    var needsQuitConfirmation: Bool {
        openEditors.contains(where: \.needsCloseConfirmation)
    }

    /// Asks about every window with unsaved edits or a running export; returns whether quitting may go ahead.
    ///
    /// Follows the Mac’s document pattern: with several unsaved windows, offer to review them one by one
    /// or discard them all.
    func confirmQuit() async -> Bool {
        var pending = openEditors.filter(\.needsCloseConfirmation)
        let unsaved = pending.filter { $0.hasUnsavedChanges && !$0.export.isRunning }
        if unsaved.count > 1 {
            let alert = NSAlert()
            alert.messageText = "You have \(unsaved.count) videos with edits that haven’t been saved."
            alert.informativeText = "Do you want to review them before quitting?"
            alert.addButton(withTitle: "Review Edits…")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Edits")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break
            case .alertThirdButtonReturn:
                // Running exports still get their own question.
                pending = pending.filter(\.export.isRunning)
            default:
                return false
            }
        }
        for editor in pending {
            editor.window?.makeKeyAndOrderFront(nil)
            guard await editor.confirmClose(quitting: true) else { return false }
        }
        return true
    }
}

import AppKit
import StillCore
import StillEditor
import SwiftUI

/// The Mac's side of an editor: its window, the export panel, recovery that opens System Settings, and asking
/// before a window closes. The editor itself lives in StillEditor, shared with the iOS app.
extension EditorModel {
    /// The window showing this editor, for sheets.
    var hostWindow: NSWindow? { window as? NSWindow }

    /// Asks for a new folder’s name and location, then exports the pair into it.
    func exportFiles() async {
        guard canExport, let folder = await chooseExportFolder() else { return }
        exportFiles(to: folder)
    }

    func recover(_ recovery: ExportFailure.Recovery, from failure: ExportFailure) {
        export.failure = nil
        switch recovery {
        case .tryAgain:
            retry(failure)
        case .exportFiles, .chooseAnotherName:
            Task { await exportFiles() }
        case .openPhotosSettings:
            NSWorkspace.shared.open(Self.photosPrivacySettings)
        }
    }

    private func chooseExportFolder() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Live Photo Files"
        panel.message = "Creates a folder with a matched JPEG and MOV. Import both into Photos together to get a Live Photo; this isn’t a single-file format."
        panel.prompt = "Export"
        panel.nameFieldLabel = "Folder Name:"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.availableFolderName(
            (sourceName as NSString).deletingPathExtension + " Live Photo", in: panel.directoryURL
        )
        let validator = ExportFolderValidator()
        panel.delegate = validator
        let response = if let hostWindow { await panel.beginSheetModal(for: hostWindow) } else { await panel.begin() }
        withExtendedLifetime(validator) {}
        guard response == .OK, let folder = panel.url else { return nil }
        // Still never replaces files, even when the panel offered to.
        if FileManager.default.fileExists(atPath: folder.path) {
            export.failure = ExportFailure(
                destination: .folder(folder),
                title: "“\(folder.lastPathComponent)” already exists",
                message: "Still never replaces existing files. Choose another name or location.",
                recoveries: [.chooseAnotherName]
            )
            return nil
        }
        return folder
    }

    /// Suggests “Name 2”, “Name 3”, … when the panel’s folder already has “Name”, so exporting the same
    /// video again doesn’t start with a name that would be refused.
    private static func availableFolderName(_ base: String, in directory: URL?) -> String {
        guard let directory else { return base }
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) && number < 100 {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    private static let photosPrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    // MARK: - Closing

    /// Asks before the window closes, or the app quits, while edits are unsaved or an export is running.
    /// Returns whether closing may go ahead.
    func confirmClose(quitting: Bool) async -> Bool {
        guard let hostWindow, needsCloseConfirmation else { return true }
        if export.isRunning {
            guard export.canCancel else {
                // A Photos commit can’t be called back; let it finish, then ask about anything still unsaved.
                await export.waitUntilFinished()
                return await confirmClose(quitting: quitting)
            }
            let alert = NSAlert()
            alert.messageText = "Stop saving this Live Photo?"
            alert.informativeText = quitting
                ? "It hasn’t finished saving. If you quit now, it won’t be saved."
                : "It hasn’t finished saving. If you close the window now, it won’t be saved."
            alert.addButton(withTitle: "Keep Saving")
            alert.addButton(withTitle: quitting ? "Stop and Quit" : "Stop and Close")
            guard await alert.beginSheetModal(for: hostWindow) == .alertSecondButtonReturn else { return false }
            export.cancel()
            await export.waitUntilFinished()
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save a Live Photo from “\(sourceName)”?"
        alert.informativeText = "Your edits will be lost if you don’t save them."
        let canSave = canExport
        if canSave { alert.addButton(withTitle: "Save to Photos") }
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let response = await alert.beginSheetModal(for: hostWindow)
        switch (canSave, response) {
        case (true, .alertFirstButtonReturn):
            // Closes only once Photos has the Live Photo.
            guard let save = saveToPhotos() else { return false }
            return await save.value
        case (true, .alertThirdButtonReturn), (false, .alertSecondButtonReturn):
            return true
        default:
            return false
        }
    }
}

/// Keeps the export panel open when the name is taken, instead of offering to replace it.
private final class ExportFolderValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
            NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” already exists.",
            NSLocalizedRecoverySuggestionErrorKey: "Still never replaces existing files. Choose another name.",
        ])
    }
}

extension FocusedValues {
    @Entry var editor: EditorModel?
}

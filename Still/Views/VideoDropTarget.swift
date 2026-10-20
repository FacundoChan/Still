import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Accepts videos dragged from Finder (file URLs) and from Photos (file promises; goal.md §5).
///
/// SwiftUI’s drop modifiers don’t resolve file promises, so this AppKit view does. It covers the window
/// for drags but lets every click through.
struct VideoDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onReceive: (URL) -> Void
    /// A promised file from Photos that never arrived.
    let onFailure: (Error) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.onReceive = onReceive
        view.onFailure = onFailure
        view.onTargetChange = { isTargeted = $0 }
    }

    final class DropView: NSView {
        var onReceive: ((URL) -> Void)?
        var onFailure: ((Error) -> Void)?
        var onTargetChange: ((Bool) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            registerForDraggedTypes([.fileURL] + promiseTypes)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // Clicks pass through to the content underneath; drags still arrive.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            let accepted = canAccept(sender.draggingPasteboard)
            onTargetChange?(accepted)
            return accepted ? .copy : []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            onTargetChange?(false)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            onTargetChange?(false)
            let pasteboard = sender.draggingPasteboard
            if let url = movieURLs(on: pasteboard).first {
                onReceive?(url)
                return true
            }
            guard let receiver = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver])?.first
            else { return false }
            guard let destination = try? TemporaryFiles.makeItemFolder(in: TemporaryFiles.drops) else { return false }
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { [weak self] url, error in
                MainActor.assumeIsolated {
                    if let error {
                        try? FileManager.default.removeItem(at: destination)
                        self?.onFailure?(error)
                    } else {
                        self?.onReceive?(url)
                    }
                }
            }
            return true
        }

        private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
            if !movieURLs(on: pasteboard).isEmpty { return true }
            let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
            return receivers.contains { receiver in
                receiver.fileTypes.contains { UTType($0)?.conforms(to: .movie) ?? false }
            }
        }

        private func movieURLs(on pasteboard: NSPasteboard) -> [URL] {
            pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.movie.identifier],
            ]) as? [URL] ?? []
        }
    }
}

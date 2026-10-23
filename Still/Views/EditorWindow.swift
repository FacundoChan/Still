import PhotosUI
import StillCore
import SwiftUI
import UniformTypeIdentifiers

/// One editor window: the empty state, or the stage, timeline, and inspector for one video.
struct EditorWindow: View {
    let request: EditorWindowRequest?

    @Environment(WindowCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @Environment(\.appearsActive) private var appearsActive
    @State private var model = EditorModel()
    @State private var isDropTargeted = false

    var body: some View {
        content
            // With the toolbar and the inspector, the window bottoms out at about 900 × 640.
            .frame(minWidth: 614, minHeight: 588)
            .overlay {
                VideoDropTarget(isTargeted: $isDropTargeted) { url in
                    model.requestOpen(url)
                } onFailure: { error in
                    model.reportImportFailure("The video couldn’t be received from Photos. \(error.localizedDescription)")
                }
            }
            .navigationTitle(model.title)
            .navigationSubtitle(model.subtitle)
            .toolbar { EditorToolbar(model: model) }
            .inspector(isPresented: .constant(model.phase == .ready)) {
                InspectorView(model: model)
                    // Ideally wide enough for the speeds at the regular size; at the minimum they fit at
                    // the small size.
                    .inspectorColumnWidth(min: 248, ideal: 286, max: 320)
            }
            .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.movie]) { result in
                if case let .success(url) = result { model.requestOpen(url) }
            }
            .photosPicker(
                isPresented: $model.isPhotosPickerPresented,
                selection: $model.photosSelection,
                matching: .videos,
                preferredItemEncoding: .current
            )
            .alert(
                model.export.failure?.title ?? "",
                isPresented: Binding(
                    get: { model.export.failure != nil },
                    set: { if !$0 { model.export.failure = nil } }
                ),
                presenting: model.export.failure
            ) { failure in
                ForEach(failure.recoveries) { recovery in
                    Button(recovery.title) { model.recover(recovery, from: failure) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .background {
                EditorWindowBridge(model: model, isEdited: model.hasUnsavedChanges)
            }
            .focusedSceneValue(\.editor, model)
            .onAppear {
                model.undoManager = undoManager
                model.coordinator = coordinator
                coordinator.register(model, openWindow: openWindow)
                coordinator.handle(request, in: model)
            }
            .onDisappear {
                coordinator.unregister(model)
                model.close()
            }
            .onChange(of: undoManager) { _, manager in model.undoManager = manager }
            .onChange(of: appearsActive, initial: true) { _, active in
                if active { coordinator.activate(model) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .ready:
            EditorContent(model: model)
        case .loading:
            ProgressView("Opening…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty, .failed:
            EmptyStateView(model: model, isDropTargeted: isDropTargeted)
        }
    }
}

/// The quiet drop target shown before a video is open.
struct EmptyStateView: View {
    @Bindable var model: EditorModel
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "livephoto")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.pulse, isActive: isDropTargeted)
            Text("Turn a video into a Live Photo")
                .font(.title2.weight(.medium))
            Text("Drop a video here from Finder or Photos, or choose one.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open Video…") { model.isImporterPresented = true }
                    .buttonStyle(.borderedProminent)
                Button("Choose from Photos…") { model.isPhotosPickerPresented = true }
            }
            .controlSize(.large)
            .padding(.top, 8)
            if case let .failed(message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(24)
                .opacity(isDropTargeted ? 1 : 0)
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @Bindable var model: EditorModel

    var body: some ToolbarContent {
        // Crop mode is entered from the inspector's Crop section, beside the controls it works with.
        if model.phase == .ready {
            ToolbarItem(placement: .primaryAction) {
                saveControl
            }
        }
    }

    @ViewBuilder
    private var saveControl: some View {
        if model.export.isRunning {
            ExportProgressView(export: model.export)
        } else {
            // A prominent button with its own menu for the secondary destination; a Menu with a primary
            // action ignores the prominent style in the toolbar.
            ControlGroup {
                Button("Save to Photos") { model.saveToPhotos() }
                    .buttonStyle(.glassProminent)
                    .help(model.state?.exportIssue?.errorDescription ?? "Save to Photos (⌘S)")
                Menu {
                    Button("Export Files…") { Task { await model.exportFiles() } }
                } label: {
                    Label("More Export Options", systemImage: "chevron.down")
                }
                .menuIndicator(.hidden)
                .help("Export Files… (⇧⌘E)")
            }
            .disabled(!model.canExport)
        }
    }
}

/// Takes the Save button’s place while exporting: the stage, overall progress, and Cancel while the stage
/// can still be cancelled.
struct ExportProgressView: View {
    var export: ExportController

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(export.stageTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: export.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            .frame(width: 128, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(export.destination == .photos ? "Saving to Photos" : "Exporting Files")
            .accessibilityValue("\(export.stageTitle) \(Int((export.progress * 100).rounded())) percent")

            Button("Cancel", systemImage: "xmark") { export.cancel() }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .disabled(!export.canCancel)
                .help(export.canCancel ? "Cancel (⌘.)" : "Saving can’t be cancelled once Photos has started")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
    }
}

/// Menu commands; they act on the focused window, or open a new one when none is open.
struct EditorCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The menu bar exists from launch; a window doesn't when Still starts by opening a video.
        let _ = WindowCoordinator.shared.provide(openWindow)
        CommandGroup(after: .newItem) {
            Button("Open Video…") { present(.presentOpenPanel) }
                .keyboardShortcut("o")
            Button("Choose from Photos…") { present(.presentPhotosPicker) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        // After, not replacing: the save group also holds Close (⌘W).
        CommandGroup(after: .saveItem) {
            Button("Save to Photos") { editor?.saveToPhotos() }
                .keyboardShortcut("s")
                .disabled(!(editor?.canExport ?? false))
            Button("Export Files…") { Task { await editor?.exportFiles() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(editor?.canExport ?? false))
            // ⌘. is the Mac’s standard “stop the current operation”.
            Button("Cancel Export") { editor?.cancelExport() }
                .keyboardShortcut(".")
                .disabled(!(editor?.export.canCancel ?? false))
        }
        // Single-key shortcuts (Space, Return, K, I, O, C, L) are handled by the editor itself, so they
        // never fire while a text field has focus; the menu lists the same actions without them.
        CommandMenu("Clip") {
            Group {
                Button(editor?.playback.isPlaying == true ? "Pause" : "Play") { editor?.togglePlayback() }
                Button("Make Key Photo") { editor?.makeKeyPhoto() }
                Button("Set Start at Playhead") { editor?.setStartAtPlayhead() }
                Button("Set End at Playhead") { editor?.setEndAtPlayhead() }
                Divider()
                Button(editor?.isCropMode == true ? "Finish Cropping" : "Crop") { editor?.isCropMode.toggle() }
                Button("Reset Crop") { editor?.resetCrop() }
                Divider()
                Button("Preview Live Photo") { editor?.previewLivePhoto() }
            }
            .disabled(editor?.phase != .ready)
        }
    }

    private func present(_ action: EditorWindowRequest.Action) {
        guard let editor else {
            WindowCoordinator.shared.openNewWindow(action)
            return
        }
        switch action {
        case .presentPhotosPicker: editor.isPhotosPickerPresented = true
        default: editor.isImporterPresented = true
        }
    }
}

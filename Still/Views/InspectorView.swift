import AppKit
import StillCore
import SwiftUI

/// Speed, duration, crop, sound, Key Photo, and the output summary (goal.md §4).
struct InspectorView: View {
    @Bindable var model: EditorModel
    @State private var isCustomRatioPresented = false
    @State private var showsCropFields = false

    var body: some View {
        if let state = model.state {
            Form {
                speedSection(state)
                durationSection(state)
                cropSection(state)
                soundSection(state)
                keyPhotoSection(state)
                outputSection(state)
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Speed

    private func speedSection(_ state: EditState) -> some View {
        Section("Speed") {
            SpeedControl(
                speeds: EditState.speeds,
                selected: state.speed,
                unavailable: Dictionary(uniqueKeysWithValues: EditState.speeds.compactMap { speed in
                    state.unavailabilityReason(forSpeed: speed).map { (speed, $0.errorDescription ?? "") }
                }),
                onSelect: { model.setSpeed($0) }
            )
            .frame(maxWidth: .infinity)
            Text(motionCaption(state))
                .font(.caption)
                .foregroundStyle(state.isMotionChoppy ? Color.orange : .secondary)
        }
    }

    private func motionCaption(_ state: EditState) -> String {
        let rate = Int(state.motionRate.rounded())
        return state.isMotionChoppy ? "\(rate) fps of motion — may look choppy" : "\(rate) fps of motion"
    }

    // MARK: - Duration

    private func durationSection(_ state: EditState) -> some View {
        Section("Duration") {
            LabeledContent("Duration") {
                HStack(spacing: 4) {
                    DurationField(value: state.outputDuration) { model.setOutputDuration($0) }
                    Text("s").foregroundStyle(.secondary)
                }
            }
            .help("The Live Photo's length, 1 to 10 seconds; the selection resizes around the Key Photo")
        }
    }

    // MARK: - Crop

    private func cropSection(_ state: EditState) -> some View {
        let isCropped = state.cropAspect != .original || state.cropRect != CropGeometry.fullFrame
        // The button shows the crop as it is, which for Freeform is whatever shape was dragged.
        let size = state.outputGeometry.renderSize
        let currentRatio = Double(size.width / size.height)
        let customRatio: Double? = if case let .custom(width, height) = state.cropAspect { width / height } else { nil }
        return Section("Crop") {
            LabeledContent("Ratio") {
                Menu {
                    ForEach(CropAspect.presets, id: \.self) { aspect in
                        Toggle(isOn: Binding(
                            get: { aspect == state.cropAspect },
                            set: { _ in model.setCropAspect(aspect) }
                        )) {
                            Label {
                                Text(aspect.title)
                            } icon: {
                                Image(nsImage: AspectGlyph.image(
                                    ratio: aspect.pixelRatio(for: state.source.orientedSize) ?? 1,
                                    dashed: aspect == .freeform
                                ))
                            }
                            // macOS menus otherwise drop a Label's icon.
                            .labelStyle(.titleAndIcon)
                        }
                    }
                    Divider()
                    // Checked, with its shape, while a custom ratio is in use.
                    Toggle(isOn: Binding(
                        get: { customRatio != nil },
                        set: { _ in isCustomRatioPresented = true }
                    )) {
                        Label {
                            Text("Custom…")
                        } icon: {
                            // Blank otherwise, so the title lines up with the others.
                            Image(nsImage: customRatio.map { AspectGlyph.image(ratio: $0) } ?? AspectGlyph.blank)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                } label: {
                    Label {
                        Text(state.cropAspect.title)
                    } icon: {
                        Image(nsImage: AspectGlyph.image(ratio: currentRatio, dashed: state.cropAspect == .freeform))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .accessibilityValue(AspectGlyph.orientation(ratio: currentRatio))
                .popover(isPresented: $isCustomRatioPresented, arrowEdge: .leading) {
                    CustomRatioForm { width, height in
                        isCustomRatioPresented = false
                        model.setCropAspect(.custom(width: width, height: height))
                    }
                }
            }
            HStack {
                if model.isCropMode {
                    Button("Done") { model.isCropMode = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Edit Crop") { model.isCropMode = true }
                        .help("Crop (C)")
                }
                Spacer()
                if isCropped {
                    Button("Reset", systemImage: "arrow.counterclockwise") { model.resetCrop() }
                        .buttonStyle(.borderless)
                        .help("Reset Crop")
                }
            }
            // A plain row rather than DisclosureGroup, which in a grouped Form ignores accessibility presses.
            Button {
                showsCropFields.toggle()
            } label: {
                HStack {
                    Text("Position and Size")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsCropFields ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsCropFields ? "Shown" : "Hidden")
            if showsCropFields {
                CropFields(state: state) { model.setCropRect($0) }
            }
        }
    }

    // MARK: - Sound

    private func soundSection(_ state: EditState) -> some View {
        Section("Sound") {
            Toggle("Sound", isOn: Binding(
                get: { state.includesAudio },
                set: { model.setIncludesAudio($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.canIncludeAudio)
            if !state.canIncludeAudio {
                Text("This video has no sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Key Photo

    private func keyPhotoSection(_ state: EditState) -> some View {
        Section("Key Photo") {
            Button {
                model.showKeyPhoto()
            } label: {
                keyPhotoThumbnail(state)
            }
            .buttonStyle(.plain)
            .help("Show the Key Photo on the stage")
            LabeledContent("Frame", value: "\(state.plan.keyPhotoFrameIndex + 1) of \(state.plan.outputFrameCount)")
                .monospacedDigit()
        }
    }

    /// The Key Photo from the preview render, so it is exactly what will be saved.
    private func keyPhotoThumbnail(_ state: EditState) -> some View {
        let current = model.livePreview.isCurrent(for: state.plan)
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            if let image = model.livePreview.keyPhoto {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(current ? 1 : 0.5)
            }
            if model.livePreview.isRendering {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Key Photo")
        .accessibilityValue(model.livePreview.isRendering ? "Updating" : "Frame \(state.plan.keyPhotoFrameIndex + 1)")
    }

    // MARK: - Output

    private func outputSection(_ state: EditState) -> some View {
        Section("Output") {
            let size = state.outputGeometry.renderSize
            Text("\(Int(size.width)) × \(Int(size.height)) · \(TimeFormat.seconds(state.outputDuration))")
                .monospacedDigit()
            Text("\(state.output.frameRate) fps · Sound \(state.includesAudio ? "on" : "off")")
                .foregroundStyle(.secondary)
            Text("About \(ByteCountFormatter.string(fromByteCount: state.estimatedFileSize, countStyle: .file))")
                .foregroundStyle(.secondary)
                .help("Estimated size of the Live Photo's photo and video")
            if state.isLowResolution {
                Label("Low resolution", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let issue = state.exportIssue {
                Label(issue.errorDescription ?? "", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                if let speed = state.suggestedSpeed {
                    Button("Use \(TimeFormat.speed(speed))") { model.setSpeed(speed) }
                }
            }
        }
    }
}

/// The output duration, in seconds.
struct DurationField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Duration", text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            .focused($isFocused)
            .onSubmit(apply)
            .onChange(of: isFocused) { _, focused in if !focused { apply() } }
            .onChange(of: value, initial: true) { _, newValue in
                if !isFocused { text = TimeFormat.fieldSeconds(newValue) }
            }
            .accessibilityLabel("Duration in seconds")
    }

    private func apply() {
        if let seconds = Double(text.trimmingCharacters(in: .whitespaces)), abs(seconds - value) > 0.0005 {
            commit(seconds)
        }
        text = TimeFormat.fieldSeconds(value)
    }
}

/// Crop position and size in source pixels (goal.md §8, numeric alternatives).
struct CropFields: View {
    let state: EditState
    let commit: (CGRect) -> Void

    var body: some View {
        let size = state.source.orientedSize
        let rect = state.cropRect
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                pixelField("X", value: rect.minX * size.width) { commit(CGRect(x: $0 / size.width, y: rect.minY, width: rect.width, height: rect.height)) }
                pixelField("Y", value: rect.minY * size.height) { commit(CGRect(x: rect.minX, y: $0 / size.height, width: rect.width, height: rect.height)) }
            }
            GridRow {
                pixelField("W", value: rect.width * size.width) { commit(CGRect(x: rect.minX, y: rect.minY, width: $0 / size.width, height: rect.height)) }
                pixelField("H", value: rect.height * size.height) { commit(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: $0 / size.height)) }
            }
        }
    }

    private func pixelField(_ label: String, value: Double, commit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            PixelField(value: value, label: label, commit: commit)
        }
    }
}

struct PixelField: View {
    let value: Double
    let label: String
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            .focused($isFocused)
            .onSubmit(apply)
            .onChange(of: isFocused) { _, focused in if !focused { apply() } }
            .onChange(of: value, initial: true) { _, newValue in
                if !isFocused { text = String(Int(newValue.rounded())) }
            }
            .accessibilityLabel("Crop \(label) in pixels")
    }

    private func apply() {
        if let pixels = Double(text.trimmingCharacters(in: .whitespaces)), abs(pixels - value) >= 0.5 {
            commit(pixels)
        }
        text = String(Int(value.rounded()))
    }
}

struct CustomRatioForm: View {
    let apply: (Double, Double) -> Void
    @State private var width = "4"
    @State private var height = "5"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Ratio").font(.headline)
            HStack {
                TextField("Width", text: $width).frame(width: 56)
                Text(":")
                TextField("Height", text: $height).frame(width: 56)
            }
            HStack {
                Spacer()
                Button("Apply") {
                    if let w = Double(width), let h = Double(height), w > 0, h > 0 { apply(w, h) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((Double(width) ?? 0) <= 0 || (Double(height) ?? 0) <= 0)
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

/// A segmented control whose speeds can be individually disabled, each with a tooltip saying why.
struct SpeedControl: NSViewRepresentable {
    let speeds: [Double]
    let selected: Double
    let unavailable: [Double: String]
    let onSelect: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> FittingSegmentedControl {
        let control = FittingSegmentedControl(
            labels: speeds.map(TimeFormat.speed),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Speed")
        return control
    }

    /// Takes the width the inspector offers instead of the control's natural width, which could push the
    /// form wider than its column.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: FittingSegmentedControl, context: Context) -> CGSize? {
        let natural = control.naturalSize(for: .regular)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural.width
        return CGSize(width: width, height: control.naturalSize(for: control.controlSize(forWidth: width)).height)
    }

    func updateNSView(_ control: FittingSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.speeds = speeds
        for (index, speed) in speeds.enumerated() {
            let reason = unavailable[speed]
            control.setEnabled(reason == nil, forSegment: index)
            control.setToolTip(reason, forSegment: index)
        }
        control.selectedSegment = speeds.firstIndex(of: selected) ?? -1
    }

    final class Coordinator: NSObject {
        var onSelect: (Double) -> Void
        var speeds: [Double] = []

        init(onSelect: @escaping (Double) -> Void) {
            self.onSelect = onSelect
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard speeds.indices.contains(sender.selectedSegment) else { return }
            onSelect(speeds[sender.selectedSegment])
        }
    }
}

/// Fits its segments to the width it's given: the regular size when the labels fit, otherwise the small
/// size. Segments share the width in proportion to their labels, so the control fills its row and never
/// draws past it.
final class FittingSegmentedControl: NSSegmentedControl {
    private var naturalSizes: [NSControl.ControlSize: CGSize] = [:]

    func controlSize(forWidth width: CGFloat) -> NSControl.ControlSize {
        width >= naturalSize(for: .regular).width ? .regular : .small
    }

    /// The width the labels need at `size`, and the control's height there; measured once on a copy.
    func naturalSize(for size: NSControl.ControlSize) -> CGSize {
        if let measured = naturalSizes[size] { return measured }
        let probe = NSSegmentedControl(
            labels: (0..<segmentCount).map { label(forSegment: $0) ?? "" },
            trackingMode: .selectOne, target: nil, action: nil
        )
        Self.style(probe, size: size)
        naturalSizes[size] = probe.intrinsicContentSize
        return probe.intrinsicContentSize
    }

    override func setFrameSize(_ newSize: NSSize) {
        let size = controlSize(forWidth: newSize.width)
        if size != controlSize || segmentDistribution != .fillProportionally { Self.style(self, size: size) }
        super.setFrameSize(newSize)
    }

    private static func style(_ control: NSSegmentedControl, size: NSControl.ControlSize) {
        control.controlSize = size
        // The control size alone keeps the regular font, and so nearly the regular width.
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        control.segmentDistribution = .fillProportionally
    }
}

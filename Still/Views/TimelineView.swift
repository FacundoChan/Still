import StillCore
import SwiftUI

/// The bottom timeline: transport, a zoomed detail strip, the whole-source overview, and a summary
/// (goal.md §6, “Timeline layout”).
struct TimelineView: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let state = model.state {
            VStack(spacing: 0) {
                KeyPhotoLane(model: model)
                    .frame(height: 30)
                TimelineStrip(model: model, kind: .detail)
                    .frame(height: 50)
                if TimelineWindow.showsOverview(sourceDuration: state.source.duration) {
                    TimelineStrip(model: model, kind: .overview)
                        .frame(height: 26)
                        .padding(.top, 6)
                }
                controls(state)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
    }

    /// Transport on the left, then the source interval, speed, and output duration.
    private func controls(_ state: EditState) -> some View {
        HStack(spacing: 6) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(model.playback.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")

            Group {
                // Output time applies to the selection as exported; 1× source playback shows source time.
                let playingSource = model.playback.isPlaying && !model.playback.showsSelectionPlayer
                if state.isInsideSelection(model.playhead) && !playingSource {
                    Text("\(TimeFormat.clock(state.outputTime(atSourceTime: model.playhead))) / \(TimeFormat.clock(state.outputDuration))")
                        .help("Output time")
                } else {
                    Text(TimeFormat.clock(model.playhead))
                        .foregroundStyle(.secondary)
                        .help("Source time")
                }
            }
            .frame(minWidth: 118, alignment: .leading)

            Spacer(minLength: 8)

            Text("Source")
                .foregroundStyle(.secondary)
            BracketButton(edge: .leading) { model.setStartAtPlayhead() }
                .help("Set start to the current frame (I)")
                .accessibilityLabel("Set Start to Current Frame")
            TimeField(value: state.selectionStart, label: "Selection start") { model.setSelectionStart($0) }
            Text("–").foregroundStyle(.secondary)
            TimeField(value: state.selectionEnd, label: "Selection end") { model.setSelectionEnd($0) }
            BracketButton(edge: .trailing) { model.setEndAtPlayhead() }
                .help("Set end to the current frame (O)")
                .accessibilityLabel("Set End to Current Frame")

            Spacer(minLength: 8)

            Text(TimeFormat.speed(state.speed))
            Spacer(minLength: 8)
            Text(TimeFormat.seconds(state.outputDuration))
                .foregroundStyle(state.exportIssue == nil ? Color.primary : Color.orange)
                .help("Output duration")
        }
        .font(.callout.monospacedDigit())
        .controlSize(.small)
    }
}

/// A small copy of a timeline bracket tab: clicking it brings that bracket to the playhead.
struct BracketButton: View {
    let edge: HorizontalEdge
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 16, height: 22)
                .background(TimelineStrip.bracketColor, in: RoundedRectangle(cornerRadius: 4))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Above the detail strip: a dot marks the Key Photo, and a Make Key Photo bubble points at the playhead
/// whenever it rests on another frame, as in Photos on iPhone (goal.md §7).
struct KeyPhotoLane: View {
    @Bindable var model: EditorModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            if let state = model.state {
                let scale = TimeScale(range: model.detailRange, width: geometry.size.width)
                let keyX = scale.x(state.keyPhotoTime)
                ZStack(alignment: .topLeading) {
                    if model.offersMakeKeyPhoto && !isDragging {
                        makeKeyPhotoBubble(atX: scale.x(model.playhead), width: geometry.size.width)
                    }
                    keyPhotoDot
                        .position(x: keyX, y: geometry.size.height - 5)
                        .gesture(dotDrag(scale: scale))
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(.named(Self.space))
            }
        }
    }

    private var keyPhotoDot: some View {
        Circle()
            .fill(Color.primary)
            .frame(width: 7, height: 7)
            .padding(6)  // A larger target for dragging.
            .contentShape(Circle())
            .help("Key Photo — drag to move it")
            .accessibilityLabel("Key Photo")
            .accessibilityValue(model.state.map { "Frame \($0.plan.keyPhotoFrameIndex + 1)" } ?? "")
    }

    private func makeKeyPhotoBubble(atX x: CGFloat, width: CGFloat) -> some View {
        let bubbleWidth: CGFloat = 122
        // Keep the bubble inside the strip; the tail still points at the playhead.
        let left = min(max(x - bubbleWidth / 2, 0), max(width - bubbleWidth, 0))
        return Button {
            model.makeKeyPhoto()
        } label: {
            Text("Make Key Photo")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: bubbleWidth, height: 20)
                .background {
                    CalloutShape(tailX: x - left)
                        .fill(Color(white: colorScheme == .dark ? 0.36 : 0.24))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: left, y: 0)
        .help("Make the frame at the playhead the Key Photo (K)")
        .transition(.opacity)
    }

    private func dotDrag(scale: TimeScale) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(KeyPhotoLane.space))
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    model.frozenDetailRange = scale.range
                    model.beginInteraction()
                }
                model.interact { $0.setKeyPhoto(at: scale.time(value.location.x)); return nil }
                if let key = model.state?.keyPhotoTime { model.preview(sourceTime: key) }
            }
            .onEnded { _ in
                isDragging = false
                model.endInteraction("Move Key Photo")
                if let key = model.state?.keyPhotoTime { model.scrub(to: key) }
            }
    }

    static let space = "KeyPhotoLane"
}

/// A rounded bubble with a tail under it at `tailX`.
nonisolated struct CalloutShape: Shape {
    var tailX: CGFloat
    var tailHeight: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: body.height / 2)
        let tip = min(max(tailX, body.minX + 10), body.maxX - 10)
        path.move(to: CGPoint(x: tip - 5, y: body.maxY - 0.5))
        path.addLine(to: CGPoint(x: tailX, y: body.maxY + tailHeight))
        path.addLine(to: CGPoint(x: tip + 5, y: body.maxY - 0.5))
        path.closeSubpath()
        return path
    }
}

/// A seconds field for the selection's start or end.
struct TimeField: View {
    let value: Double
    let label: String
    let commit: (Double) -> Void

    var body: some View {
        NumericField(
            label: label, value: value, tolerance: 0.0005, format: TimeFormat.fieldSeconds,
            parse: { Double($0.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)) },
            commit: commit
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 64)
        .accessibilityLabel(label)
        .accessibilityValue(TimeFormat.seconds(value))
    }
}

/// One timeline strip. The detail strip trims with iPhone-style brackets; the overview moves the selection.
/// Dragging outside the selection scrubs.
struct TimelineStrip: View {
    enum Kind { case detail, overview }

    @Bindable var model: EditorModel
    let kind: Kind

    private enum DragMode {
        case scrub
        case move(startSelection: Double, startTime: Double)
        case trimStart
        case trimEnd
    }

    /// Width of the bracket tabs at each end of the selection.
    static let bracketWidth: CGFloat = 12

    @State private var dragMode: DragMode?

    var body: some View {
        GeometryReader { geometry in
            if let state = model.state, let source = model.source {
                let range = kind == .detail ? model.detailRange : 0...state.source.duration
                let scale = TimeScale(range: range, width: geometry.size.width)
                let selection = scale.x(state.selectionStart)...scale.x(state.selectionEnd)

                ZStack(alignment: .topLeading) {
                    filmstrip(range: range, scale: scale, height: geometry.size.height)

                    // Outside the selection is dimmed. The cutout follows the brackets' rounded corners, so no
                    // undimmed sliver shows outside them.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        let window = CGRect(x: selection.lowerBound, y: 0, width: max(selection.upperBound - selection.lowerBound, 0), height: geometry.size.height)
                        if kind == .detail {
                            path.addRoundedRect(in: window, cornerSize: CGSize(width: BracketFrame.cornerRadius, height: BracketFrame.cornerRadius))
                        } else {
                            path.addRect(window)
                        }
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                    if kind == .detail {
                        ticks(state: state, range: range, scale: scale, height: geometry.size.height)
                    }

                    selectionFrame(selection: selection, height: geometry.size.height)

                    playheadMarker(x: scale.x(model.playhead), height: geometry.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(dragGesture(state: state, scale: scale, range: range))
                .onAppear { requestThumbnails(source: source, range: range, size: geometry.size, state: state) }
                .onChange(of: range) { _, newRange in requestThumbnails(source: source, range: newRange, size: geometry.size, state: state) }
                .onChange(of: geometry.size) { _, size in requestThumbnails(source: source, range: range, size: size, state: state) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(kind == .detail ? "Selection detail" : "Whole video")
                .accessibilityValue("Selection \(TimeFormat.seconds(state.selectionStart)) to \(TimeFormat.seconds(state.selectionEnd)), playhead \(TimeFormat.seconds(model.playhead))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.step(1)
                    case .decrement: model.step(-1)
                    @unknown default: break
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    /// Each thumbnail covers its own slot of source time, so images from a previous range stay in the
    /// right place while new ones load.
    private func filmstrip(range: ClosedRange<Double>, scale: TimeScale, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.secondary.opacity(0.15))
            ForEach(model.thumbnails.thumbnails(strip, in: range)) { thumbnail in
                Image(nsImage: thumbnail.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: CGFloat(thumbnail.slot.span * scale.pointsPerSecond) + 0.5, height: height)
                    .clipped()
                    .offset(x: scale.x(thumbnail.slot.start))
            }
        }
        .frame(width: scale.width, height: height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func ticks(state: EditState, range: ClosedRange<Double>, scale: TimeScale, height: CGFloat) -> some View {
        Canvas { context, size in
            let frameDuration = 1 / max(state.source.frameRate, 1)
            let spacing = scale.pointsPerSecond * frameDuration
            guard spacing >= TimelineWindow.minimumTickSpacing else { return }
            var path = Path()
            var time = (range.lowerBound / frameDuration).rounded(.up) * frameDuration
            while time <= range.upperBound {
                let x = scale.x(time)
                path.move(to: CGPoint(x: x, y: size.height - 5))
                path.addLine(to: CGPoint(x: x, y: size.height))
                time += frameDuration
            }
            context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// Yellow trim brackets, as for video on iPhone and in QuickTime Player: they always trim.
    private func selectionFrame(selection: ClosedRange<CGFloat>, height: CGFloat) -> some View {
        let width = max(selection.upperBound - selection.lowerBound, 2)
        return Group {
            if kind == .detail {
                BracketFrame(tabWidth: Self.bracketWidth)
                    .fill(Self.bracketColor, style: FillStyle(eoFill: true))
                    .frame(width: width, height: height)
                    .overlay(alignment: .leading) { chevron("chevron.compact.left") }
                    .overlay(alignment: .trailing) { chevron("chevron.compact.right") }
                    .offset(x: selection.lowerBound)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Self.bracketColor, lineWidth: 2)
                    .frame(width: width, height: height)
                    .offset(x: selection.lowerBound)
            }
        }
        .allowsHitTesting(false)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black.opacity(0.75))
            .frame(width: Self.bracketWidth)
    }

    static let bracketColor = Color(red: 1, green: 0.8, blue: 0.0)

    private func playheadMarker(x: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 2, height: height)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .offset(x: x - 1)
            .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private func dragGesture(state: EditState, scale: TimeScale, range: ClosedRange<Double>) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = scale.time(value.location.x)
                let mode = dragMode ?? beginDrag(at: value.startLocation, state: state, scale: scale, range: range)
                switch mode {
                case .scrub:
                    model.scrub(to: time)
                case let .move(startSelection, startTime):
                    model.interact { $0.moveSelection(toStart: startSelection + time - startTime); return nil }
                    if let key = model.state?.keyPhotoTime { model.preview(sourceTime: key) }
                case .trimStart:
                    model.interact { $0.setSelectionStart(time) }
                    if let start = model.state?.selectionStart { model.preview(sourceTime: start) }
                case .trimEnd:
                    model.interact { $0.setSelectionEnd(time) }
                    if let end = model.state?.selectionEnd { model.preview(sourceTime: end) }
                }
            }
            .onEnded { value in
                defer { dragMode = nil }
                switch dragMode {
                case let .move(_, startTime) where abs(value.translation.width) < 3:
                    // A click inside the selection moves the playhead rather than the selection.
                    model.endInteraction("Move Selection")
                    model.scrub(to: startTime)
                case .move:
                    model.endInteraction("Move Selection")
                    model.scrub(to: model.playhead)
                case .trimStart, .trimEnd:
                    model.endInteraction("Trim")
                    model.scrub(to: model.playhead)
                case .scrub, nil:
                    model.frozenDetailRange = nil
                }
            }
    }

    private func beginDrag(at point: CGPoint, state: EditState, scale: TimeScale, range: ClosedRange<Double>) -> DragMode {
        if kind == .detail { model.frozenDetailRange = range }
        let start = scale.x(state.selectionStart)
        let end = scale.x(state.selectionEnd)
        // The bracket tabs sit just inside each end; the hit area reaches a few points beyond them.
        let tab = Self.bracketWidth
        let onStart = point.x >= start - 6 && point.x <= start + tab + 2
        let onEnd = point.x >= end - tab - 2 && point.x <= end + 6
        let mode: DragMode
        if kind == .detail && onStart && (!onEnd || abs(point.x - start) <= abs(point.x - end)) {
            mode = .trimStart
        } else if kind == .detail && onEnd {
            mode = .trimEnd
        } else if point.x > start && point.x < end {
            mode = .move(startSelection: state.selectionStart, startTime: scale.time(point.x))
        } else {
            mode = .scrub
        }
        if case .scrub = mode {} else { model.beginInteraction() }
        dragMode = mode
        return mode
    }

    private func requestThumbnails(source: SourceMedia, range: ClosedRange<Double>, size: CGSize, state: EditState) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = state.source.orientedSize.width / max(state.source.orientedSize.height, 1)
        // The source time one thumbnail covers at its natural width.
        let span = (range.upperBound - range.lowerBound) * Double(size.height * aspect / size.width)
        model.thumbnails.load(strip, source: source, range: range, thumbnailSpan: span)
    }

    private var strip: ThumbnailProvider.Strip {
        kind == .detail ? .detail : .overview
    }
}

/// The trim frame: a rounded outline with wide tabs at both ends, filled even-odd.
nonisolated struct BracketFrame: Shape {
    static let cornerRadius: CGFloat = 6

    var tabWidth: CGFloat
    var border: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: Self.cornerRadius)
        let inner = rect.insetBy(dx: tabWidth, dy: border)
        if inner.width > 0 {
            path.addRoundedRect(in: inner, cornerSize: CGSize(width: 2, height: 2))
        }
        return path
    }
}

/// Maps between source seconds and points across a strip.
struct TimeScale {
    let range: ClosedRange<Double>
    let width: CGFloat

    var span: Double { max(range.upperBound - range.lowerBound, 0.0001) }
    var pointsPerSecond: Double { Double(width) / span }

    func x(_ time: Double) -> CGFloat {
        CGFloat((time - range.lowerBound) / span) * width
    }

    func time(_ x: CGFloat) -> Double {
        range.lowerBound + Double(x / max(width, 1)) * span
    }
}

enum TimeFormat {
    /// mm:ss.cc with monospaced digits in mind.
    static func clock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, rest)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    /// “1 s”, “4.2 s”: slider end labels.
    static func shortSeconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) s" : String(format: "%.1f s", rounded)
    }

    static func fieldSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func speed(_ value: Double) -> String {
        let text = value.rounded() == value ? String(Int(value)) : String(value)
        return "\(text)×"
    }
}

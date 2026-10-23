import StillCore
import SwiftUI

/// Crop mode on the stage: the full frame with everything outside the crop dimmed.
/// Drag inside to move; drag a handle to resize. Fixed ratios resize from the corners only.
struct CropOverlay: View {
    @Bindable var model: EditorModel
    /// The full oriented frame on the stage.
    let frame: CGRect

    @State private var dragStart: CGRect?
    @State private var isAdjusting = false

    private enum Handle: CaseIterable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var id: Self { self }
        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    }

    var body: some View {
        if let state = model.state {
            let crop = displayRect(state.cropRect)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(frame)
                    path.addRect(crop)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                if isAdjusting {
                    thirds(in: crop)
                }

                Rectangle()
                    .path(in: crop)
                    .stroke(Color.white, lineWidth: 1)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: crop.width, height: crop.height)
                    .offset(x: crop.minX, y: crop.minY)
                    .gesture(moveGesture(state))
                    .accessibilityLabel("Crop area")

                ForEach(handles(for: state)) { handle in
                    handleView(handle)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .position(point(of: handle, in: crop))
                        .gesture(resizeGesture(handle, state: state))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Geometry

    private func displayRect(_ normalized: CGRect) -> CGRect {
        CGRect(x: frame.minX + normalized.minX * frame.width, y: frame.minY + normalized.minY * frame.height,
               width: normalized.width * frame.width, height: normalized.height * frame.height)
    }

    private func handles(for state: EditState) -> [Handle] {
        state.cropAspect == .freeform ? Handle.allCases : Handle.allCases.filter(\.isCorner)
    }

    private func point(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    // MARK: - Gestures

    private func moveGesture(_ state: EditState) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = beginDrag(state)
                let moved = start.offsetBy(dx: value.translation.width / frame.width,
                                           dy: value.translation.height / frame.height)
                model.interact { $0.setCropRect(moved); return nil }
            }
            .onEnded { _ in endDrag("Move Crop") }
    }

    private func resizeGesture(_ handle: Handle, state: EditState) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = beginDrag(state)
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                let resized = resize(start, handle: handle, dx: dx, dy: dy, state: state)
                model.interact { $0.setCropRect(resized); return nil }
            }
            .onEnded { _ in endDrag("Resize Crop") }
    }

    private func beginDrag(_ state: EditState) -> CGRect {
        if let dragStart { return dragStart }
        model.beginInteraction()
        dragStart = state.cropRect
        isAdjusting = true
        return state.cropRect
    }

    private func endDrag(_ actionName: String) {
        model.endInteraction(actionName)
        dragStart = nil
        isAdjusting = false
    }

    /// Moves the dragged edges and keeps the opposite ones fixed; fixed ratios follow the horizontal drag.
    private func resize(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat, state: EditState) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .top: minY += dy
        case .topRight: maxX += dx; minY += dy
        case .right: maxX += dx
        case .bottomRight: maxX += dx; maxY += dy
        case .bottom: maxY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .left: minX += dx
        }
        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        guard state.cropAspect != .freeform,
              let ratio = state.cropAspect.pixelRatio(for: state.source.orientedSize) else { return rect }
        // Normalized height for this width at the fixed pixel ratio, anchored at the opposite corner.
        let size = state.source.orientedSize
        let height = rect.width * size.width / size.height / ratio
        switch handle {
        case .topLeft, .topRight: rect.origin.y = start.maxY - height
        default: rect.origin.y = start.minY
        }
        rect.size.height = height
        return rect
    }

    // MARK: - Drawing

    private func thirds(in rect: CGRect) -> some View {
        Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            }
        }
        .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: Handle) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            let arm: CGFloat = 12
            switch handle {
            case .topLeft:
                path.move(to: CGPoint(x: center.x, y: center.y + arm)); path.addLine(to: center); path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            case .topRight:
                path.move(to: CGPoint(x: center.x - arm, y: center.y)); path.addLine(to: center); path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            case .bottomRight:
                path.move(to: CGPoint(x: center.x, y: center.y - arm)); path.addLine(to: center); path.addLine(to: CGPoint(x: center.x - arm, y: center.y))
            case .bottomLeft:
                path.move(to: CGPoint(x: center.x + arm, y: center.y)); path.addLine(to: center); path.addLine(to: CGPoint(x: center.x, y: center.y - arm))
            case .top, .bottom:
                path.move(to: CGPoint(x: center.x - arm / 2, y: center.y)); path.addLine(to: CGPoint(x: center.x + arm / 2, y: center.y))
            case .left, .right:
                path.move(to: CGPoint(x: center.x, y: center.y - arm / 2)); path.addLine(to: CGPoint(x: center.x, y: center.y + arm / 2))
            }
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: .black.opacity(0.4), radius: 1)
        .accessibilityLabel("Crop handle")
    }
}

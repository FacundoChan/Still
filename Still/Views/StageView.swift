import AVKit
import Photos
import PhotosUI
import StillCore
import SwiftUI

/// The stage, timeline, and keyboard handling for an open video.
struct EditorContent: View {
    @Bindable var model: EditorModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StageView(model: model)
            Divider()
            TimelineView(model: model)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            // Keys typed in a Source field belong to it, Return and Space included.
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return .ignored }
            return model.handleKey(press) ? .handled : .ignored
        }
        .simultaneousGesture(TapGesture().onEnded {
            // Taking focus here would pull it straight back out of a Source field the click just focused.
            if !Self.isTextFieldClick { isFocused = true }
        })
        .onAppear { isFocused = true }
    }

    /// Whether the click being handled landed in a text field.
    private static var isTextFieldClick: Bool {
        guard let event = NSApp.currentEvent, let window = event.window,
              let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        // NSText covers the field editor, which sits over a text field while it's being edited.
        return hit is NSTextField || hit is NSText
    }
}

/// Shows the video exactly as it will export, or the full frame with the crop overlay in Crop mode.
struct StageView: View {
    @Bindable var model: EditorModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fit(model.stageContentSize, in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 16, dy: 16))
            ZStack(alignment: .topLeading) {
                Color.clear

                player(model.playback.sourcePlayer, in: frame)
                    .opacity(model.playback.showsSelectionPlayer ? 0 : 1)
                player(model.playback.selectionPlayer, in: frame)
                    .opacity(model.playback.showsSelectionPlayer ? 1 : 0)

                if model.livePreview.isPlaying, let photo = model.livePreview.livePhoto {
                    LivePhotoPlayer(livePhoto: photo) { model.livePreview.stop() }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }

                if model.isCropMode {
                    CropOverlay(model: model, frame: frame)
                } else {
                    HStack(spacing: 6) {
                        LiveBadge(model: model)
                        if model.isShowingKeyPhoto && !model.livePreview.isPlaying {
                            // Says which frame becomes the photo, as the dot does on the timeline.
                            Text("Key Photo")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .transition(.opacity)
                                .accessibilityLabel("Showing the Key Photo")
                        }
                    }
                    .offset(x: frame.minX + 10, y: frame.minY + 10)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.isShowingKeyPhoto)
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 12) {
                // Press and hold plays the Live Photo, as on iPhone.
                if !model.isCropMode { model.previewLivePhoto() }
            } onPressingChanged: { pressing in
                if !pressing && model.livePreview.isPlaying { model.livePreview.stop() }
            }
        }
        .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.9))
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.notice)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    private func player(_ player: AVPlayer, in frame: CGRect) -> some View {
        PlayerView(player: player)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }

    /// The largest rectangle with `content`’s aspect ratio that fits `bounds`, centered.
    static func fit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// The LIVE badge: hovering or clicking plays the Live Photo preview, as in Photos for Mac.
struct LiveBadge: View {
    var model: EditorModel

    var body: some View {
        let available = model.state?.exportIssue == nil
        HStack(spacing: 4) {
            Image(systemName: "livephoto")
            Text("LIVE")
                .font(.caption.weight(.semibold))
            if model.livePreview.isRendering {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .opacity(available ? 1 : 0.5)
        .onHover { hovering in
            if hovering && available { model.previewLivePhoto() }
        }
        .onTapGesture { model.previewLivePhoto() }
        .help("Preview Live Photo (L)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview Live Photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.previewLivePhoto() }
    }
}

/// AppKit’s player view without controls; the stage sizes it to the video exactly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        // Referencing AVPlayerView directly links AVKit. SwiftUI's VideoPlayer crashes on macOS 27.0
        // when nothing else loads AVKit.
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The system Live Photo player, so the preview plays exactly as Photos does.
struct LivePhotoPlayer: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        view.delegate = context.coordinator
        view.livePhoto = livePhoto
        // The stage already shows a LIVE badge.
        view.livePhotoBadgeView?.isHidden = true
        DispatchQueue.main.async { view.startPlayback(with: .full) }
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onFinish = onFinish
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
            view.startPlayback(with: .full)
        }
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            onFinish()
        }
    }
}

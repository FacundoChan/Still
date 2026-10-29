import AVFoundation
import CoreGraphics
import ImageIO
import Testing
@testable import StillCore

/// Captions drawn into the Live Photo's video: the transcript, how it's split into cues and timed, and the frames.
@Suite("Captions", .serialized)
struct CaptionTests {
    static let speech = Fixture(
        name: "speech-sdr-30fps-6s.mov", kind: .synthetic, expectedSize: CGSize(width: 1280, height: 720), hasAudio: true, selectionStart: 0
    )
    static let speechHDR = Fixture(
        name: "speech-hdr-hlg-30fps-6s.mov", kind: .synthetic, expectedSize: CGSize(width: 1280, height: 720), hasAudio: true, selectionStart: 0
    )

    /// What the speech fixtures say, with even word timings: a pause from 0.8 s to 2 s leaves the captions empty for
    /// a while.
    static let phrases: [[SpokenWord]] = [
        words("Hello there.", from: 0.2, to: 0.8),
        words("This is a test of captions in a Live Photo.", from: 2.0, to: 3.4),
        words("Do you see the boats out on the water?", from: 3.6, to: 5.6),
    ]

    static func words(_ text: String, from start: Double, to end: Double) -> [SpokenWord] {
        let parts = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(parts.count)
        return parts.enumerated().map { index, part in
            SpokenWord(text: (index == 0 ? "" : " ") + part, start: start + Double(index) * step, end: start + Double(index + 1) * step)
        }
    }

    // MARK: - Transcription

    @Test func transcribesWhatIsSaid() async throws {
        let source = try await SourceMedia.load(Self.speech.url)
        guard let language = await SpeechTranscription.supportedLanguage(for: "en-US") else { return }
        let transcript = try await SpeechTranscription.transcribe(source, language: language)
        let words = transcript.phrases.flatMap { $0 }
        let text = words.map(\.text).joined().lowercased()
        #expect(text.contains("captions"), "\(text)")
        // The last sentence ends about 5.4 s in: the transcript reaches the end of the speech.
        #expect((words.last?.end ?? 0) > 4.5, "\(text)")
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= 6.1 })
    }

    @Test func silentVideosHaveNothingToTranscribe() async throws {
        let silent = Fixture(name: "silent-landscape-30fps-4s.mov", kind: .synthetic, expectedSize: Fixture.landscape, hasAudio: false, selectionStart: 0)
        let source = try await SourceMedia.load(silent.url)
        await #expect(throws: SpeechTranscriptionError.self) {
            try await SpeechTranscription.transcribe(source, language: Locale(identifier: "en-US"))
        }
    }

    // MARK: - Cues

    @Test func cuesAreTwoLinesAtMostAndKeepEveryWord() {
        let long = Self.words(
            "We are walking to the beach today, and the weather is lovely, so we will stay until the sun goes down behind the hills.",
            from: 0, to: 6
        )
        let plan = EditPlan(selection: CMTimeRange(start: .zero, duration: .seconds(6)), keyPhotoSourceTime: .seconds(1))
        let size = CGSize(width: 1080, height: 1920)
        let overlay = CaptionOverlay(BurnedCaptions(phrases: [long], style: .current), plan: plan, renderSize: size)
        let layout = CaptionOverlay.Layout(style: .current, renderSize: size)

        #expect(overlay.cues.count > 1)
        #expect(overlay.cues.allSatisfy { layout.lineCount($0.text) <= CaptionOverlay.maxLines })
        #expect(overlay.cues.map(\.text).joined(separator: " ") == CaptionOverlay.Layout.text(of: long))
        #expect(zip(overlay.cues, overlay.cues.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
    }

    @Test func cuesFollowOutputTime() {
        // Selection from 1 s at half speed: a word said at source 2 s shows at output 2 s.
        let phrase = [SpokenWord(text: "Hello.", start: 2, end: 2.5)]
        let plan = EditPlan(selection: CMTimeRange(start: .seconds(1), duration: .seconds(2)), speed: 0.5, keyPhotoSourceTime: .seconds(2))
        let overlay = CaptionOverlay(BurnedCaptions(phrases: [phrase], style: .current), plan: plan, renderSize: Fixture.landscape)
        let cue = try? #require(overlay.cues.first)
        #expect(abs((cue?.start ?? 0) - 2) < 1e-9)
        #expect(abs((cue?.end ?? 0) - (3 + CaptionOverlay.linger)) < 1e-9)
        #expect(overlay.cue(at: 1.9) == nil)
        #expect(overlay.cue(at: 2.1) != nil)
    }

    @Test func wordsOutsideTheSelectionShowNothing() {
        let plan = EditPlan(selection: CMTimeRange(start: .seconds(10), duration: .seconds(3)), keyPhotoSourceTime: .seconds(11))
        let overlay = CaptionOverlay(BurnedCaptions(phrases: Self.phrases, style: .current), plan: plan, renderSize: Fixture.landscape)
        #expect(overlay.cues.isEmpty)
    }

    @Test(arguments: [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 406, height: 720), CGSize(width: 720, height: 120)])
    func cuesStayInsideTheFrame(_ size: CGSize) {
        let plan = EditPlan(selection: CMTimeRange(start: .zero, duration: .seconds(6)), keyPhotoSourceTime: .seconds(1))
        for profile in CaptionStyle.profiles {
            let overlay = CaptionOverlay(BurnedCaptions(phrases: Self.phrases, style: CaptionStyle(profileID: profile.id)), plan: plan, renderSize: size)
            let frame = CGRect(origin: .zero, size: size)
            for cue in overlay.cues {
                #expect(frame.contains(cue.extent), "\(profile.name) at \(size): \(cue.extent)")
                #expect(cue.extent.minX.truncatingRemainder(dividingBy: 2) == 0 && cue.extent.minY.truncatingRemainder(dividingBy: 2) == 0)
            }
        }
    }

    // MARK: - Rendering

    /// Captioned frames show bright text in the cue's place over the dark fixture; frames between cues don't, and the
    /// Key Photo doesn't even while a cue shows at its moment.
    @Test(arguments: [speech, speechHDR])
    func drawsCaptionsIntoTheMovieButNotTheKeyPhoto(_ fixture: Fixture) async throws {
        let source = try await SourceMedia.load(fixture.url)
        var state = try EditState(source: source.info)
        state.setKeyPhoto(at: 2.5)
        var plan = state.plan
        plan.captions = BurnedCaptions(phrases: Self.phrases, style: .current)

        let directory = Fixture.outputDirectory(for: "captions-" + fixture.name)
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")
        let overlay = CaptionOverlay(try #require(plan.captions), plan: plan, renderSize: pair.pixelSize)
        let key = try #require(overlay.cue(at: plan.keyPhotoFrameTime.seconds), "A cue shows at the Key Photo")
        #expect(overlay.cue(at: 1.7) == nil)

        // Output frames at 0.5 s (first cue), 1.7 s (between cues) and 2.5 s (the Key Photo's cue).
        let frames = try await MediaProbe.movieFrames(pair.videoURL, at: [15, 51, 75])
        let first = try #require(overlay.cue(at: 0.5))
        #expect(Self.brightest(try #require(frames[15]), in: first.extent) > 150)
        #expect(Self.brightest(try #require(frames[51]), in: first.extent) < 100)
        #expect(Self.brightest(try #require(frames[75]), in: key.extent) > 150)

        let photo = try MediaProbe.image(at: pair.imageURL)
        #expect(Self.brightest(photo, in: key.extent) < 100, "The Key Photo has no caption")

        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// The brightest luma inside `rect`, given in Core Image's coordinates (origin at the bottom left).
    static func brightest(_ frame: MediaProbe.DecodedFrame, in rect: CGRect) -> UInt8 {
        var brightest: UInt8 = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let row = (frame.height - 1 - y) * frame.width
            for x in Int(rect.minX)..<Int(rect.maxX) { brightest = max(brightest, frame.luma[row + x]) }
        }
        return brightest
    }

    /// The brightest channel value inside `rect` of an image, given in Core Image's coordinates.
    static func brightest(_ image: CGImage, in rect: CGRect) -> UInt8 {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var brightest: UInt8 = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let row = (height - 1 - y) * width * 4
            for x in Int(rect.minX)..<Int(rect.maxX) {
                brightest = max(brightest, pixels[row + x * 4], pixels[row + x * 4 + 1], pixels[row + x * 4 + 2])
            }
        }
        return brightest
    }
}

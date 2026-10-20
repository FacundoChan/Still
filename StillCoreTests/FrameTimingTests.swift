import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import StillCore

/// A frame-coded fixture and the trim to apply.
struct TimingCase: Sendable, CustomTestStringConvertible {
    let fixture: String
    /// Rate the frame code was stamped at: source frame i sits at i / rate seconds.
    let codeRate: Double
    /// Codes that exist in the source; the VFR clip drops two of every seven.
    let exists: @Sendable (Int) -> Bool
    let start: Double
    let speed: Double

    var testDescription: String { "\(fixture) from \(start) s at \(speed)×" }

    static let offGrid = 1.0 / 300

    static let all: [TimingCase] = {
        let everyFrame: @Sendable (Int) -> Bool = { _ in true }
        let vfr: @Sendable (Int) -> Bool = { $0 % 7 < 5 }
        var cases: [TimingCase] = []
        for speed in EditState.speeds {
            cases.append(TimingCase(fixture: "framecode-30fps-6s.mov", codeRate: 30, exists: everyFrame, start: 0.5 + offGrid, speed: speed))
        }
        // Starts on a source frame, so many output times tie exactly with a source frame.
        cases.append(TimingCase(fixture: "framecode-30fps-6s.mov", codeRate: 30, exists: everyFrame, start: 1, speed: 0.5))
        cases.append(TimingCase(fixture: "framecode-30fps-6s.mov", codeRate: 30, exists: everyFrame, start: 0, speed: 2))
        for speed in [0.5, 1, 1.5] {
            cases.append(TimingCase(fixture: "framecode-vfr-6s.mov", codeRate: 30, exists: vfr, start: 0.5 + offGrid, speed: speed))
        }
        for speed in [0.5, 0.75, 1] {
            cases.append(TimingCase(fixture: "framecode-120fps-4s.mov", codeRate: 120, exists: everyFrame, start: 0.5 + offGrid, speed: speed))
        }
        return cases
    }()

    /// Source frames a correct render may show at `sourceTime`: the latest frame at or before it, or at an
    /// exact tie (within a millisecond) the one before as well, since either is a valid reading.
    func acceptableCodes(at sourceTime: Double) -> Set<Int> {
        let position = sourceTime * codeRate
        var latest = Int((position + 1e-9).rounded(.down))
        while latest > 0 && !exists(latest) { latest -= 1 }
        var codes: Set<Int> = [latest]
        let nearest = Int(position.rounded())
        if abs(position - Double(nearest)) * (1 / codeRate) < 1e-3 {
            var before = nearest - 1
            while before > 0 && !exists(before) { before -= 1 }
            codes.insert(before)
            if exists(nearest) { codes.insert(nearest) }
        }
        return codes
    }
}

@Suite("Frame timing", .serialized)
struct FrameTimingTests {
    /// Every output frame shows the source frame the time model predicts (goal.md §6 and §7):
    /// output frame k at k / 30 s shows source time start + k / 30 × speed.
    @Test(arguments: TimingCase.all)
    func everyFrameShowsThePredictedSourceFrame(_ timing: TimingCase) async throws {
        let url = Fixture.root.appending(path: "Fixtures/synthetic/\(timing.fixture)")
        let source = try await SourceMedia.load(url)
        var state = try EditState(source: source.info)
        try state.setSpeed(timing.speed)
        state.moveSelection(toStart: timing.start)
        state.setKeyPhoto(at: state.selectionStart + 1.3 * timing.speed)
        let plan = state.plan

        let directory = Fixture.outputDirectory(for: "timing/\(timing.testDescription)")
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")

        let indices = Array(0..<plan.outputFrameCount)
        let frames = try await MediaProbe.movieFrames(pair.videoURL, at: indices)
        #expect(frames.count == indices.count)
        var mismatches: [String] = []
        for index in indices {
            let frame = try #require(frames[index])
            let shown = MediaProbe.frameCode(frame)
            let sourceTime = state.selectionStart + Double(index) / 30 * timing.speed
            let acceptable = timing.acceptableCodes(at: sourceTime)
            if !acceptable.contains(shown) {
                mismatches.append("frame \(index) shows \(shown), expected \(acceptable.sorted())")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(8).joined(separator: "; "))")

        // The Key Photo is the movie’s frame at the marker time, and the frame the time model predicts.
        let keyCode = try MediaProbe.frameCode(MediaProbe.image(at: pair.imageURL))
        let movieKeyCode = MediaProbe.frameCode(try #require(frames[plan.keyPhotoFrameIndex]))
        #expect(keyCode == movieKeyCode, "Key Photo shows \(keyCode), movie frame shows \(movieKeyCode)")
        let keySourceTime = state.selectionStart + Double(plan.keyPhotoFrameIndex) / 30 * timing.speed
        #expect(timing.acceptableCodes(at: keySourceTime).contains(keyCode))
        let marker = try #require(try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL).stillImageTime)
        #expect(marker == pair.keyPhotoTime)
    }
}

extension MediaProbe {
    /// Reads the 12-bar binary frame code from a decoded frame’s luma plane.
    static func frameCode(_ frame: DecodedFrame) -> Int {
        let row = frame.height / 2
        return (0..<12).reduce(0) { code, bit in
            let x = Int((Double(bit) + 0.5) * Double(frame.width) / 12)
            return frame.luma[row * frame.width + x] > 128 ? code | (1 << bit) : code
        }
    }

    /// Reads the frame code from an image, such as the Key Photo JPEG.
    static func frameCode(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let row = height / 2
        return (0..<12).reduce(0) { code, bit in
            let x = Int((Double(bit) + 0.5) * Double(width) / 12)
            return pixels[row * width + x] > 128 ? code | (1 << bit) : code
        }
    }
}

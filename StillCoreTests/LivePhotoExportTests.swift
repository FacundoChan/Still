import CoreMedia
import Foundation
import Testing
@testable import StillCore

/// Goal A inner loop: export each fixture and check the pair without touching the Photos library.
@Suite("Live Photo export", .serialized)
struct LivePhotoExportTests {
    @Test(arguments: Fixture.goalA.filter(\.isAvailable))
    func exportsRecognizedLivePhoto(_ fixture: Fixture) async throws {
        try #require(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "Missing \(fixture.url.path). Run Scripts/make-fixtures.sh, or add the real clip."
        )
        let source = try await SourceMedia.load(fixture.url)
        let plan = EditPlan.centered(start: fixture.selectionStart, duration: 3)

        let directory = Fixture.outputDirectory(for: fixture.name)
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")

        let frame = plan.frameDuration.seconds
        #expect(pair.keyPhotoTime == plan.keyPhotoFrameTime)
        #expect(pair.pixelSize == fixture.expectedSize)
        #expect(pair.hasAudio == fixture.hasAudio)

        let inspection = try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(inspection.identifiersMatch, "image \(String(describing: inspection.imageContentIdentifier)) vs movie \(String(describing: inspection.videoContentIdentifier))")
        #expect(inspection.imageContentIdentifier == pair.contentIdentifier)
        let stillImageTime = try #require(inspection.stillImageTime, "No still-image-time marker in the movie")
        #expect(abs(stillImageTime.seconds - plan.keyPhotoFrameTime.seconds) < 1e-3)
        #expect(abs(inspection.videoDuration.seconds - 3) <= frame)
        #expect(inspection.videoFrameCount == 90)
        #expect(inspection.videoCodec == kCMVideoCodecType_HEVC)
        #expect(inspection.videoPixelSize == fixture.expectedSize)
        #expect(inspection.imagePixelSize == fixture.expectedSize)
        #expect(inspection.hasAudio == fixture.hasAudio)

        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// At 4K and a high bit rate the photo and the video are 4K, and Photos still pairs them.
    @Test(arguments: Fixture.uhd.filter(\.isAvailable))
    func exportsAt4K(_ fixture: Fixture) async throws {
        let source = try await SourceMedia.load(fixture.url)
        var plan = EditPlan.centered(start: fixture.selectionStart, duration: 3)
        plan.output.maxLongEdge = OutputResolution.uhd.maxLongEdge
        plan.output.bitsPerPixel = VideoBitRate.high.bitsPerPixel

        let directory = Fixture.outputDirectory(for: "4K-" + fixture.name)
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")

        let inspection = try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(inspection.videoPixelSize == fixture.expectedSize)
        #expect(inspection.imagePixelSize == fixture.expectedSize)
        #expect(inspection.identifiersMatch)
        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// HDR sources export HDR by default: a 10-bit HLG movie and a Key Photo with a gain map, which Photos pairs.
    @Test(arguments: Fixture.hdr.filter(\.isAvailable))
    func exportsHDR(_ fixture: Fixture) async throws {
        let source = try await SourceMedia.load(fixture.url)
        #expect(source.isHDR)
        var state = try EditState(source: source.info)
        #expect(state.isHDR)
        state.moveSelection(toStart: fixture.selectionStart)

        let directory = Fixture.outputDirectory(for: "HDR-" + fixture.name)
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(state.plan, source: source, to: directory, baseName: "LivePhoto")

        let inspection = try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(inspection.videoCodec == kCMVideoCodecType_HEVC)
        #expect(inspection.videoTransferFunction == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        #expect(inspection.videoBitsPerComponent == 10)
        #expect(inspection.imageHasGainMap)
        #expect(inspection.videoPixelSize == fixture.expectedSize && inspection.imagePixelSize == fixture.expectedSize)
        #expect(inspection.identifiersMatch)
        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// With HDR off, an HDR source gives the standard result: 8-bit Rec. 709 and a plain JPEG.
    @Test func hdrSourceCanExportStandardRange() async throws {
        let fixture = try #require(Fixture.hdr.first)
        let source = try await SourceMedia.load(fixture.url)
        var state = try EditState(source: source.info)
        state.setHDR(false)
        #expect(!state.isHDR)

        let directory = Fixture.outputDirectory(for: "SDR-" + fixture.name)
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(state.plan, source: source, to: directory, baseName: "LivePhoto")
        let inspection = try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(inspection.videoTransferFunction == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(inspection.videoBitsPerComponent != 10)
        #expect(!inspection.imageHasGainMap)
    }

    /// 720p gives a 720p pair, and the bit rate reaches the encoder: Very High makes a larger movie than Low.
    @Test func resolutionAndBitRateReachTheExport() async throws {
        let fixture = try #require(Fixture.goalA.first { $0.name == "landscape-sdr-30fps-6s.mov" })
        let source = try await SourceMedia.load(fixture.url)
        var movieSizes: [VideoBitRate: Int] = [:]
        var calibrations: [VideoBitRate: SizeCalibration] = [:]
        for bitRate in [VideoBitRate.low, .veryHigh] {
            var plan = EditPlan.centered(start: fixture.selectionStart, duration: 3)
            plan.output.maxLongEdge = OutputResolution.hd.maxLongEdge
            plan.output.bitsPerPixel = bitRate.bitsPerPixel
            let directory = Fixture.outputDirectory(for: "720p-\(bitRate.rawValue)")
            try? FileManager.default.removeItem(at: directory)
            let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")
            #expect(pair.pixelSize == CGSize(width: 1280, height: 720))
            movieSizes[bitRate] = try FileManager.default.attributesOfItem(atPath: pair.videoURL.path)[.size] as? Int
            calibrations[bitRate] = try await SizeCalibration.measure(pair, plan: plan)
        }
        let low = try #require(movieSizes[.low]), veryHigh = try #require(movieSizes[.veryHigh])
        // The test pattern needs few bits, so the encoder leaves most of Very High unused, and the size estimate
        // has to learn that from a render rather than trust the target.
        let calibration = try #require(calibrations[.veryHigh])
        #expect(calibration.videoRateFactor < 0.5)
        #expect(calibration.photoBytesPerPixel > 0)
        print("MEASURE 720p movie: low \(low) bytes, very high \(veryHigh) bytes")
        #expect(Double(veryHigh) > Double(low) * 1.5)
    }

    /// Negative control: the pairing check must reject an image and movie whose identifiers differ,
    /// otherwise a passing check proves nothing.
    @Test func pairingCheckRejectsMismatchedIdentifiers() async throws {
        let fixture = Fixture.goalA[0]
        let source = try await SourceMedia.load(fixture.url)
        let plan = EditPlan.centered(start: 1, duration: 3)
        let directory = Fixture.outputDirectory(for: "mismatch-check")
        try? FileManager.default.removeItem(at: directory)
        let first = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "First")
        let second = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "Second")
        #expect(first.contentIdentifier != second.contentIdentifier)

        let pairing = await LivePhotoInspector.checkPairing(imageURL: first.imageURL, videoURL: second.videoURL)
        #expect(pairing != .paired, "Photos paired files with different content identifiers")
    }

    @Test func refusesToOverwriteExistingFiles() async throws {
        let fixture = Fixture.goalA[0]
        let source = try await SourceMedia.load(fixture.url)
        let plan = EditPlan.centered(start: 1, duration: 3)
        let directory = Fixture.outputDirectory(for: "overwrite-check")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appending(path: "LivePhoto.MOV")
        try Data("keep me".utf8).write(to: existing)

        await #expect(throws: LivePhotoExportError.self) {
            try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")
        }
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "LivePhoto.JPG").path))
    }

    @Test func rejectsPlansOutsideTheProductRange() async throws {
        let fixture = Fixture.goalA[0]
        let source = try await SourceMedia.load(fixture.url)
        let directory = Fixture.outputDirectory(for: "invalid-plan")
        await #expect(throws: LivePhotoExportError.self) {
            try await LivePhotoExporter().export(.centered(start: 0, duration: 0.5), source: source, to: directory, baseName: "LivePhoto")
        }
    }
}

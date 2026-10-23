import AVFoundation
import CoreMedia
import Foundation
import ImageIO
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

    /// The Live Photo keeps the video's date (at the Key Photo's moment) and camera, and its location only when
    /// the edit includes it.
    @Test(arguments: [false, true])
    func carriesCaptureMetadata(includesLocation: Bool) async throws {
        let fixture = try #require(Fixture.goalA.first { $0.name == "landscape-sdr-30fps-6s.mov" })
        let source = try await SourceMedia.load(try await Self.taggedCopy(of: fixture.url))
        #expect(source.capture.model == "iPhone 15 Pro" && source.capture.timeZoneOffset == 8 * 3600)
        #expect(source.capture.location?.latitude == 48.8584)
        var plan = EditPlan.centered(start: 1, duration: 3)
        plan.includesLocation = includesLocation

        let directory = Fixture.outputDirectory(for: "metadata-\(includesLocation)")
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")

        // Recorded at 15:36:27 (UTC+8); the Key Photo is 2.5 s in.
        #expect(pair.captureDate == Date(timeIntervalSince1970: 1_716_276_989.5))
        #expect((pair.location != nil) == includesLocation)
        let imageSource = try #require(CGImageSourceCreateWithURL(pair.imageURL as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:21 15:36:29")
        #expect(exif[kCGImagePropertyExifSubsecTimeOriginal] as? String == "500")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+08:00")
        #expect(tiff[kCGImagePropertyTIFFMake] as? String == "Apple" && tiff[kCGImagePropertyTIFFModel] as? String == "iPhone 15 Pro")
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        #expect((gps != nil) == includesLocation)
        if let gps { #expect(gps[kCGImagePropertyGPSLatitude] as? Double == 48.8584 && gps[kCGImagePropertyGPSLatitudeRef] as? String == "N") }

        let movie = try await AVURLAsset(url: pair.videoURL).load(.metadata)
        func value(_ key: String) async -> String? {
            let identifier = AVMetadataIdentifier(rawValue: "mdta/\(key)")
            return try? await AVMetadataItem.metadataItems(from: movie, filteredByIdentifier: identifier).first?.load(.stringValue)
        }
        #expect(await value("com.apple.quicktime.creationdate") == "2024-05-21T15:36:28+0800", "The movie starts 1 s in")
        #expect(await value("com.apple.quicktime.model") == "iPhone 15 Pro")
        #expect((await value("com.apple.quicktime.location.ISO6709") != nil) == includesLocation)

        let inspection = try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(inspection.identifiersMatch)
        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// A copy of `url` with the QuickTime capture metadata iPhone writes, and a public landmark as its location.
    /// ffmpeg can only write these keys as an iTunes list, which isn't what iPhone videos carry.
    private static func taggedCopy(of url: URL) async throws -> URL {
        let output = Fixture.outputDirectory(for: "tagged-source").appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough))
        session.metadata = [
            ("com.apple.quicktime.creationdate", "2024-05-21T15:36:27+0800"),
            ("com.apple.quicktime.make", "Apple"),
            ("com.apple.quicktime.model", "iPhone 15 Pro"),
            ("com.apple.quicktime.software", "17.4.1"),
            ("com.apple.quicktime.location.ISO6709", "+48.8584+002.2945+035.000/"),
        ].map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        try await session.export(to: output, as: .mov)
        return output
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

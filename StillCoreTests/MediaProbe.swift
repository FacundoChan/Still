import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Testing
@testable import StillCore

/// Measurements on rendered media, used to check output against preview and source.
enum MediaProbe {
    // MARK: - Frames

    /// The frame displayed at `time`, rendered through `videoComposition` when one is given.
    static func frame(
        of asset: AVAsset,
        at time: CMTime,
        videoComposition: AVVideoComposition? = nil
    ) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time).image
    }

    /// A decoded 4:2:0 frame: tightly packed luma and interleaved chroma planes, plus an sRGB image made
    /// the same way the Key Photo writer makes its JPEG.
    struct DecodedFrame {
        let width: Int
        let height: Int
        let luma: [UInt8]
        let chroma: [UInt8]
        let image: CGImage
    }

    /// What playback shows at each requested 30 fps grid index: the composition read in order, as AVPlayer
    /// plays it, taking the latest frame at or before each grid time.
    ///
    /// `AVAssetImageGenerator` can’t serve as this reference: on random access it tone-maps Dolby Vision
    /// differently from playback (washed out after the first frame), while AVPlayer and the exporter agree.
    static func playbackFrames(_ graph: RenderGraph, at indices: [Int64]) throws -> [Int64: DecodedFrame] {
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: graph.composition.tracks(withMediaType: .video), videoSettings: planarSettings
        )
        output.videoComposition = graph.videoComposition
        return try frames(from: output, of: reader, at: indices)
    }

    /// The movie’s frames at the requested 30 fps grid indices, decoded in order.
    static func movieFrames(_ url: URL, at indices: [Int64]) async throws -> [Int64: DecodedFrame] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        return try frames(from: AVAssetReaderTrackOutput(track: track, outputSettings: planarSettings), of: reader, at: indices)
    }

    /// PSNR over the luma and chroma planes together, with no color conversion involved.
    static func psnr(_ a: DecodedFrame, _ b: DecodedFrame) -> Double {
        guard a.width == b.width, a.height == b.height else { return -.infinity }
        let first = vDSP.integerToFloatingPoint(a.luma + a.chroma, floatingPointType: Float.self)
        let second = vDSP.integerToFloatingPoint(b.luma + b.chroma, floatingPointType: Float.self)
        let meanSquaredError = Double(vDSP.distanceSquared(first, second)) / Double(first.count)
        return meanSquaredError == 0 ? .infinity : 10 * log10(255 * 255 / meanSquaredError)
    }

    private static var planarSettings: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }

    private static func frames(from output: AVAssetReaderOutput, of reader: AVAssetReader, at indices: [Int64]) throws -> [Int64: DecodedFrame] {
        reader.add(output)
        reader.startReading()
        let wanted = indices.sorted()
        var frames: [Int64: DecodedFrame] = [:]
        var next = 0
        var previous: CMSampleBuffer?
        func take(_ sample: CMSampleBuffer?, before time: Double) {
            while next < wanted.count, Double(wanted[next]) / 30 < time - 1e-6 {
                if let sample, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    frames[wanted[next]] = decodedFrame(buffer)
                }
                next += 1
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            take(previous, before: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            previous = sample
        }
        take(previous, before: .infinity)
        return frames
    }

    private static func decodedFrame(_ buffer: CVPixelBuffer) -> DecodedFrame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func plane(_ index: Int, bytesPerRow: Int, rows: Int) -> [UInt8] {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * rows)
            for row in 0..<rows {
                bytes.withUnsafeMutableBufferPointer { destination in
                    (destination.baseAddress! + row * bytesPerRow).update(from: base + row * stride, count: bytesPerRow)
                }
            }
            return bytes
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let luma = plane(0, bytesPerRow: width, rows: height)
        let chroma = plane(1, bytesPerRow: CVPixelBufferGetWidthOfPlane(buffer, 1) * 2, rows: CVPixelBufferGetHeightOfPlane(buffer, 1))
        guard let image = image(from: buffer) else { return nil }
        return DecodedFrame(width: width, height: height, luma: luma, chroma: chroma, image: image)
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Converts a rendered Rec. 709 buffer to sRGB the same way the Key Photo writer does. An HLG buffer stays
    /// in HLG, so its highlights survive.
    static func image(from buffer: CVPixelBuffer) -> CGImage? {
        for (key, value) in [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ] where CVBufferCopyAttachment(buffer, key, nil) == nil {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let isHLG = transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: isHLG ? CGColorSpace.itur_2100_HLG : CGColorSpace.sRGB)!)
    }

    /// The source frame at `time`, oriented, cropped to `crop`, and scaled to `size`: what the
    /// output should show, computed without the render pipeline.
    static func expectedFrame(source: AVAsset, at time: CMTime, crop: CGRect, size: CGSize) async throws -> CGImage {
        let full = try await frame(of: source, at: time)
        let width = CGFloat(full.width), height = CGFloat(full.height)
        let rect = CGRect(x: crop.minX * width, y: crop.minY * height, width: crop.width * width, height: crop.height * height)
        let cropped = try #require(full.cropping(to: rect.integral))
        return try #require(render(cropped, size: size))
    }

    /// Writes a PNG so a failed comparison can be inspected by eye.
    static func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// With `hdr`, an image with a gain map is decoded as HDR, the gain map applied.
    static func image(at url: URL, hdr: Bool = false) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options = hdr ? [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary : nil
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, options))
    }

    /// Peak signal-to-noise ratio over RGB, in dB, after drawing both images into `space` at `a`’s size.
    static func psnr(_ a: CGImage, _ b: CGImage, in space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> Double {
        let size = CGSize(width: a.width, height: a.height)
        let pixelsA = rgba(a, size: size, space: space), pixelsB = rgba(b, size: size, space: space)
        let floatsA = vDSP.integerToFloatingPoint(pixelsA, floatingPointType: Float.self)
        let floatsB = vDSP.integerToFloatingPoint(pixelsB, floatingPointType: Float.self)
        // Both images are opaque, so alpha contributes nothing to the distance.
        let squaredError = Double(vDSP.distanceSquared(floatsA, floatsB))
        let meanSquaredError = squaredError / Double(a.width * a.height * 3)
        return meanSquaredError == 0 ? .infinity : 10 * log10(255 * 255 / meanSquaredError)
    }

    private static func render(_ image: CGImage, size: CGSize) -> CGImage? {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(origin: .zero, size: size))
        return context?.makeImage()
    }

    private static func rgba(_ image: CGImage, size: CGSize, space: CGColorSpace) -> [UInt8] {
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if space.name != CGColorSpace.sRGB {
            // Core Image converts extended-range and HDR images into HLG, which Core Graphics bitmaps can't hold.
            let input = CIImage(cgImage: image)
            let scaled = input.transformed(by: CGAffineTransform(scaleX: size.width / input.extent.width, y: size.height / input.extent.height))
            context.render(scaled, toBitmap: &pixels, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size),
                           format: .RGBA8, colorSpace: space)
            return pixels
        }
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.interpolationQuality = .high
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    // MARK: - Timing

    static func videoPresentationTimes(_ url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        return times.sorted { $0 < $1 }
    }

    /// Presentation times of frames whose center is bright, keeping only the first of each run.
    static func flashOnsets(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var frames: [(time: Double, bright: Bool)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, centerLuma(buffer) > 128))
        }
        frames.sort { $0.time < $1.time }
        var onsets: [Double] = []
        var previous = false
        for frame in frames {
            if frame.bright && !previous { onsets.append(frame.time) }
            previous = frame.bright
        }
        return onsets
    }

    private static func centerLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = (CVPixelBufferGetHeight(buffer) / 2) * row + (CVPixelBufferGetWidth(buffer) / 2) * 4
        return (Double(base[pixel]) + Double(base[pixel + 1]) + Double(base[pixel + 2])) / 3
    }

    // MARK: - Audio

    struct Audio {
        let samples: [Float]
        let sampleRate: Double
        /// Presentation time of the first decoded sample.
        let startTime: Double

        var duration: Double { Double(samples.count) / sampleRate }
    }

    /// The movie’s audio, decoded to mono 32-bit float, or nil if it has no audio track.
    static func audio(_ url: URL) async throws -> Audio? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let sampleRate = 44_100.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        var startTime: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if startTime == nil { startTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        return Audio(samples: samples, sampleRate: sampleRate, startTime: startTime ?? 0)
    }

    /// Frequency of a steady tone between two times, from zero crossings with a small hysteresis.
    static func toneFrequency(_ audio: Audio, from start: Double, to end: Double) -> Double {
        let first = Int(start * audio.sampleRate), last = min(Int(end * audio.sampleRate), audio.samples.count)
        var crossings = 0
        var positive: Bool?
        for index in first..<last {
            let value = audio.samples[index]
            if value > 0.01, positive != true {
                if positive == false { crossings += 1 }
                positive = true
            } else if value < -0.01, positive != false {
                if positive == true { crossings += 1 }
                positive = false
            }
        }
        return Double(crossings) / 2 / (Double(last - first) / audio.sampleRate)
    }

    /// Start times of beeps separated by at least 0.2 s of quiet.
    static func beepOnsets(_ audio: Audio, threshold: Float = 0.2) -> [Double] {
        let gap = Int(0.2 * audio.sampleRate)
        var onsets: [Double] = []
        var lastLoud = -gap - 1
        for (index, value) in audio.samples.enumerated() where abs(value) > threshold {
            if index - lastLoud > gap {
                onsets.append(audio.startTime + Double(index) / audio.sampleRate)
            }
            lastLoud = index
        }
        return onsets
    }
}

import AVFoundation

extension SizeCalibration {
    /// Measures an exported pair against the plan it was rendered from.
    public static func measure(_ pair: LivePhotoPair, plan: EditPlan) async throws -> SizeCalibration {
        let asset = AVURLAsset(url: pair.videoURL)
        let pixels = Double(pair.pixelSize.width * pair.pixelSize.height)
        var factor = 1.0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let spent = Double(try await track.load(.estimatedDataRate))
            let asked = Double(plan.output.averageVideoBitRate(for: pair.pixelSize))
            if spent > 0, asked > 0 { factor = spent / asked }
        }
        let photoBytes = try FileManager.default.attributesOfItem(atPath: pair.imageURL.path)[.size] as? Int ?? 0
        return SizeCalibration(videoRateFactor: factor, photoBytesPerPixel: Double(photoBytes) / max(pixels, 1), pixelCount: pixels)
    }
}

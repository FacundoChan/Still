import CoreLocation
import Photos

extension PhotosLibrarySaver {
    /// Adds a movie to the Photos library as a video, and returns once Photos has confirmed creation. Photos copies the
    /// file, so it can be shared or removed afterwards.
    ///
    /// - Parameters:
    ///   - originalFilename: base name Photos records for the file. During development pass a `StillTest-` prefix so
    ///     test assets are easy to find.
    ///   - creationDate: when the video was recorded, so it sits beside the original; nil dates it now.
    ///   - location: where it was taken, or nil for none.
    public static func saveVideo(at url: URL, originalFilename: String, creationDate: Date?, location: CaptureLocation?) async throws {
        try await ensureAddAccess()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let creationDate { request.creationDate = creationDate }
                if let location {
                    request.location = CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                        altitude: location.altitude ?? 0,
                        horizontalAccuracy: location.horizontalAccuracy ?? 0,
                        verticalAccuracy: location.altitude == nil ? -1 : 0,
                        timestamp: creationDate ?? Date()
                    )
                }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "\(originalFilename).\(url.pathExtension.uppercased())"
                request.addResource(with: .video, fileURL: url, options: options)
            }
        } catch {
            if (error as? PHPhotosError)?.code == .accessUserDenied { throw PhotosSaveError.accessDenied }
            throw PhotosSaveError.saveFailed(error)
        }
    }
}

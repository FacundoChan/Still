import CoreLocation
import MapKit
import StillCore

/// Place names from Apple Maps. They're looked up for a location the user includes or is choosing, or, on iPhone, a
/// video's own location when its info is open.
public enum PlaceNames {
    private static var cache: [String: String] = [:]

    public static func name(for location: CaptureLocation) async -> String? {
        let key = location.cacheKey
        if let cached = cache[key] { return cached }
        guard let request = MKReverseGeocodingRequest(location: location.clLocation),
              let item = try? await request.mapItems.first
        else { return nil }
        let name = item.addressRepresentations?.cityWithContext ?? item.name ?? item.address?.shortAddress
        if let name { cache[key] = name }
        return name
    }
}

public extension CaptureLocation {
    nonisolated var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    nonisolated var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    nonisolated var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
    }

    /// About 10 m: close enough that the same place shares a name.
    nonisolated var cacheKey: String { String(format: "%.4f,%.4f", latitude, longitude) }

    /// “48.8584° N, 2.2945° E”.
    nonisolated var coordinateText: String {
        String(format: "%.4f° %@, %.4f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

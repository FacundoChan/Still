import CoreLocation
import MapKit
import StillCore
import SwiftUI

/// Place names from Apple Maps. They're looked up only for a location the user includes or is choosing, so
/// coordinates leave the Mac only once the user has chosen to share them.
@MainActor
enum PlaceNames {
    private static var cache: [String: String] = [:]

    static func name(for location: CaptureLocation) async -> String? {
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

/// The included location on a small map, with its place name and controls in the map's corner.
struct LocationPreview<Controls: View>: View {
    let location: CaptureLocation
    @ViewBuilder let controls: Controls
    @State private var placeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(location.region), interactionModes: []) {
                // The name is under the map.
                Marker("", coordinate: location.coordinate)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            // A new location recenters the map.
            .id(location.cacheKey)
            .accessibilityLabel(placeName.map { "Map of \($0)" } ?? "Map")
            .overlay(alignment: .bottomTrailing) { controls.padding(8) }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(placeName ?? location.coordinateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: location.cacheKey) { placeName = await PlaceNames.name(for: location) }
    }
}

/// Search for a place or click the map to put the pin there.
struct LocationPicker: View {
    let initial: CaptureLocation?
    let choose: (CaptureLocation) -> Void
    let cancel: () -> Void

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var placeName: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    init(initial: CaptureLocation?, choose: @escaping (CaptureLocation) -> Void, cancel: @escaping () -> Void) {
        self.initial = initial
        self.choose = choose
        self.cancel = cancel
        _coordinate = State(initialValue: initial?.coordinate)
        _position = State(initialValue: initial.map { .region($0.region) } ?? .automatic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search for a place", text: $query)
                    .textFieldStyle(.roundedBorder)
                    // Typing starts in the search, never in the editor behind the popover.
                    .focused($isSearchFocused)
                    .onAppear { isSearchFocused = true }
                    // Results follow the typing; Return takes the first.
                    .onChange(of: query) { scheduleSearch() }
                    .onSubmit { if let first = results.first { pick(first) } }
                if isSearching { ProgressView().controlSize(.small) }
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results, id: \.self) { item in
                        Button { pick(item) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "Unnamed place")
                                if let detail = item.addressRepresentations?.cityWithContext {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
            MapReader { proxy in
                Map(position: $position) {
                    if let coordinate { Marker(placeName ?? "", coordinate: coordinate) }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .onTapGesture(coordinateSpace: .local) { point in
                    if let tapped = proxy.convert(point, from: .local) { coordinate = tapped }
                }
            }
            .frame(width: 380, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(coordinate == nil ? "Search, or click the map to place the pin." : placeName ?? chosenLocation?.coordinateText ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { if let chosenLocation { choose(chosenLocation) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenLocation == nil)
            }
        }
        .padding(16)
        .task(id: chosenLocation?.cacheKey) {
            guard let chosenLocation else { return }
            placeName = nil
            placeName = await PlaceNames.name(for: chosenLocation)
        }
    }

    private var chosenLocation: CaptureLocation? {
        coordinate.map { CaptureLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Waits for a pause in typing, so Apple Maps isn't asked about every keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.resultTypes = [.address, .pointOfInterest]
            isSearching = true
            let response = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            isSearching = false
            results = Array((response?.mapItems ?? []).prefix(5))
        }
    }

    private func pick(_ item: MKMapItem) {
        coordinate = item.location.coordinate
        position = .region(MKCoordinateRegion(center: item.location.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
        results = []
    }
}

extension CaptureLocation {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
    }

    /// About 10 m: close enough that the same place shares a name.
    var cacheKey: String { String(format: "%.4f,%.4f", latitude, longitude) }

    /// “48.8584° N, 2.2945° E”.
    var coordinateText: String {
        String(format: "%.4f° %@, %.4f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

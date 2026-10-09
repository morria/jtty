import CoreLocation
import Foundation

/// Finds the phone's Maidenhead grid square, once, when asked.
@Observable
final class GridLocator: NSObject, CLLocationManagerDelegate {
    private(set) var isLocating = false
    private(set) var errorMessage: String?
    private let manager = CLLocationManager()
    private var completion: ((String) -> Void)?

    func locate(_ completion: @escaping (String) -> Void) {
        self.completion = completion
        errorMessage = nil
        isLocating = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isLocating = false
            errorMessage = "Location access is off for JTTY. Type the grid, or allow location in Settings."
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isLocating else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted:
            isLocating = false
            errorMessage = "Location access is off for JTTY."
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        isLocating = false
        completion?(Self.grid(for: location.coordinate))
        completion = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLocating = false
        errorMessage = "Could not find the location."
    }

    /// Six-character Maidenhead locator.
    static func grid(for coordinate: CLLocationCoordinate2D) -> String {
        let lon = coordinate.longitude + 180, lat = coordinate.latitude + 90
        let field = "ABCDEFGHIJKLMNOPQR".map { $0 }
        let sub = "abcdefghijklmnopqrstuvwx".map { $0 }
        let a = field[min(17, Int(lon / 20))], b = field[min(17, Int(lat / 10))]
        let c = Int(lon.truncatingRemainder(dividingBy: 20) / 2), d = Int(lat.truncatingRemainder(dividingBy: 10))
        let e = sub[min(23, Int(lon.truncatingRemainder(dividingBy: 2) * 12))]
        let f = sub[min(23, Int(lat.truncatingRemainder(dividingBy: 1) * 24))]
        return "\(a)\(b)\(c)\(d)\(e)\(f)"
    }
}

import Combine
import CoreLocation
import Foundation

@MainActor
protocol LocationManaging: AnyObject {
  var delegate: (any CLLocationManagerDelegate)? { get set }
  var authorizationStatus: CLAuthorizationStatus { get }
  var accuracyAuthorization: CLAccuracyAuthorization { get }
  var desiredAccuracy: CLLocationAccuracy { get set }
  func requestWhenInUseAuthorization()
  func requestTemporaryFullAccuracyAuthorization(
    withPurposeKey purposeKey: String, completion: (@Sendable (Error?) -> Void)?)
  func requestLocation()
  func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var lastLocationText = ""
  @Published private(set) var authorizationStatus: CLAuthorizationStatus

  @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization

  private let manager: any LocationManaging
  private var continuations: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
  private var authorizationRequested = false
  private var preciseLocation = true
  private var accuracyRequested = false
  private var isRequestingAccuracy = false
  private var isRequestingLocation = false
  private var timeoutTask: Task<Void, Never>?

  init(manager: any LocationManaging = CLLocationManager()) {
    self.manager = manager
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  var permissionText: String {
    switch authorizationStatus {
    case .notDetermined:
      "Location permission has not been requested."
    case .denied:
      "Location access is denied or Location Services are off. Enable access in iOS Settings."
    case .restricted:
      "Location access is restricted on this device."
    case .authorizedWhenInUse, .authorizedAlways:
      accuracyAuthorization == .fullAccuracy
        ? "Precise location access is allowed while using PocketMai."
        : "Only approximate location is allowed. Enable Precise Location in iOS Settings for better accuracy."
    @unknown default:
      "Location access is unavailable."
    }
  }

  func requestAuthorization(precise: Bool = true) {
    preciseLocation = precise
    manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyReduced
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    if authorizationStatus == .notDetermined {
      guard !authorizationRequested else { return }
      authorizationRequested = true
      manager.requestWhenInUseAuthorization()
    } else {
      requestPreciseAuthorizationIfNeeded()
    }
  }

  private func requestPreciseAuthorizationIfNeeded() {
    guard preciseLocation, manager.accuracyAuthorization == .reducedAccuracy,
      authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways,
      !accuracyRequested, !isRequestingAccuracy
    else { return }
    accuracyRequested = true
    isRequestingAccuracy = true
    manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseLocation") {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.accuracyRequested = true
        self.isRequestingAccuracy = false
        self.resumeAfterAuthorization()
      }
    }
  }

  func currentLocationText(precise: Bool = true) async -> String {
    guard let location = await requestLocation(precise: precise) else {
      let authorized =
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
      let reason =
        authorized
        ? "Could not obtain a recent position. Try again with a clear GPS signal." : permissionText
      let text = "Location unavailable. \(reason)"
      lastLocationText = text
      return text
    }
    let text = String(
      format: "Latitude %.5f, longitude %.5f (accuracy ±%.0f m; measured %@)",
      locale: Locale(identifier: "en_US_POSIX"),
      location.coordinate.latitude, location.coordinate.longitude,
      location.horizontalAccuracy, ISO8601DateFormatter().string(from: location.timestamp))
    lastLocationText = text
    return text
  }

  func currentCoordinate(precise: Bool = true) async -> CLLocationCoordinate2D? {
    await requestLocation(precise: precise)?.coordinate
  }

  private func requestLocation(precise: Bool) async -> CLLocation? {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        continuations[id] = continuation
        requestAuthorization(precise: precise)
        resumeAfterAuthorization()
      }
    } onCancel: {
      Task { @MainActor in
        self.continuations.removeValue(forKey: id)?.resume(returning: nil)
        if self.continuations.isEmpty { self.stopRequest() }
      }
    }
  }

  private func resumeAfterAuthorization() {
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    guard !continuations.isEmpty else { return }
    switch authorizationStatus {
    case .notDetermined:
      // Keep the first message pending until the user answers the system prompt.
      return
    case .authorizedWhenInUse, .authorizedAlways:
      requestPreciseAuthorizationIfNeeded()
      guard !isRequestingAccuracy, !isRequestingLocation else { return }
      isRequestingLocation = true
      timeoutTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        self?.finishRequest(with: nil)
      }
      manager.requestLocation()
    default:
      finishRequest(with: nil)
    }
  }

  private func stopRequest() {
    timeoutTask?.cancel()
    timeoutTask = nil
    if isRequestingLocation { manager.stopUpdatingLocation() }
    isRequestingLocation = false
    accuracyRequested = false
  }

  private func finishRequest(with location: CLLocation?) {
    stopRequest()
    let pending = continuations
    continuations.removeAll()
    for continuation in pending.values { continuation.resume(returning: location) }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor in
      if self.manager.authorizationStatus != .notDetermined { authorizationRequested = false }
      resumeAfterAuthorization()
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    Task { @MainActor in
      guard isRequestingLocation else { return }
      // Never describe an old cached fix as the user's current position.
      let location = locations.last {
        $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) <= 30
      }
      finishRequest(with: location)
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      guard isRequestingLocation else { return }
      finishRequest(with: nil)
    }
  }
}

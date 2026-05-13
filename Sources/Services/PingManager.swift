import Foundation
import Combine

// MARK: - PingManager
//
// Thin facade for API compatibility. Views now use PingEngine directly via @StateObject.
@MainActor
final class PingManager: ObservableObject {
    @Published var pingInterval: TimeInterval = 1.0

    let engine = PingEngine()

    var results: [PingResult] { engine.results }
    var isRunning: Bool { engine.isRunning }

    private var engineObserver: AnyCancellable?

    init() {
        engineObserver = engine.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    func startPinging(hosts: [String]) {
        guard !isRunning, !hosts.isEmpty else { return }
        engine.pingInterval = pingInterval
        engine.start(hosts: hosts)
    }

    func stopPinging() { engine.stop() }
    func clearResults() { engine.clear() }
}

import Foundation
import Network

/// Measures a Wi-Fi-only TCP handshake without blocking the sensor polling queue.
final class NetworkLatencyMonitor {
    private let queue = DispatchQueue(label: "ThermoBar.network-latency", qos: .utility)
    private let sampleInterval: TimeInterval = 5
    private let timeout: TimeInterval = 1.5

    private var connection: NWConnection?
    private var lastAttempt = Date.distantPast
    private var latestMilliseconds: Double?

    func readLatency() -> Double? {
        queue.sync {
            if connection == nil, Date().timeIntervalSince(lastAttempt) >= sampleInterval {
                startMeasurement()
            }
            return latestMilliseconds
        }
    }

    private func startMeasurement() {
        lastAttempt = Date()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let candidate = NWConnection(host: "1.1.1.1", port: 443, using: parameters)
        let startedAt = Date()
        connection = candidate

        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, self.connection === candidate else { return }
            switch state {
            case .ready:
                self.latestMilliseconds = max(0, Date().timeIntervalSince(startedAt) * 1_000)
                self.finish(candidate)
            case .failed, .cancelled:
                self.latestMilliseconds = nil
                self.finish(candidate)
            default:
                break
            }
        }
        candidate.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak candidate] in
            guard let self, let candidate, self.connection === candidate else { return }
            self.latestMilliseconds = nil
            self.finish(candidate)
        }
    }

    private func finish(_ candidate: NWConnection) {
        candidate.stateUpdateHandler = nil
        candidate.cancel()
        if connection === candidate {
            connection = nil
        }
    }
}

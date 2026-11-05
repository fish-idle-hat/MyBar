import Foundation
import FanControlProtocol

enum MonitoringMode: String, CaseIterable, Codable {
    case live = "Live"
    case balanced = "Balanced"
    case eco = "Eco"

    var refreshInterval: TimeInterval {
        switch self {
        case .live, .balanced: return 1
        case .eco: return 2
        }
    }

    var temperatureBatchSize: Int {
        switch self {
        case .live: return 96
        case .balanced: return 48
        case .eco: return 24
        }
    }

    var topAppsInterval: TimeInterval {
        switch self {
        case .live: return 3
        case .balanced: return 5
        case .eco: return 15
        }
    }

    var storageInterval: TimeInterval {
        switch self {
        case .live: return 30
        case .balanced: return 60
        case .eco: return 120
        }
    }
}

enum SensorConfidence: String, Codable {
    case live = "Live"
    case delayed = "Delayed"
    case staticReading = "Static"
    case unreliable = "Unreliable"
}

struct SensorHealth: Codable, Equatable {
    let confidence: SensorConfidence
    let age: TimeInterval
    let unchangedSamples: Int
}

struct ThermalPrediction: Codable, Equatable {
    let temperature: Double
    let slopePerMinute: Double
    let headroomTo80: Double
    let minutesTo80: Double?
    let minutesTo90: Double?

    var summary: String {
        if let minutesTo80, minutesTo80 <= 30 {
            return String(format: "%.0f°C headroom · 80°C in %.0f min", headroomTo80, minutesTo80)
        }
        if slopePerMinute > 0.25 {
            return String(format: "%.0f°C headroom · +%.1f°C/min", headroomTo80, slopePerMinute)
        }
        return String(format: "%.0f°C headroom · Stable", headroomTo80)
    }
}

final class ThermalPredictor {
    private struct Sample {
        let date: Date
        let temperature: Double
    }

    private var samples: [Sample] = []

    func update(temperature: Double?, at date: Date) -> ThermalPrediction? {
        guard let temperature, temperature.isFinite else { return nil }
        samples.append(Sample(date: date, temperature: temperature))
        samples.removeAll { date.timeIntervalSince($0.date) > 120 }

        let recent = samples.filter { date.timeIntervalSince($0.date) <= 45 }
        let slope = Self.regressionSlope(samples: recent)
        let perMinute = slope * 60
        func eta(to target: Double) -> Double? {
            guard perMinute > 0.25, temperature < target else { return temperature >= target ? 0 : nil }
            return min(240, max(0, (target - temperature) / perMinute))
        }
        return ThermalPrediction(
            temperature: temperature,
            slopePerMinute: perMinute,
            headroomTo80: max(0, 80 - temperature),
            minutesTo80: eta(to: 80),
            minutesTo90: eta(to: 90)
        )
    }

    private static func regressionSlope(samples: [Sample]) -> Double {
        guard samples.count >= 4, let first = samples.first else { return 0 }
        let points = samples.map { (x: $0.date.timeIntervalSince(first.date), y: $0.temperature) }
        let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = points.reduce(0) { $0 + pow($1.x - meanX, 2) }
        guard denominator > 0 else { return 0 }
        return max(-2, min(2, numerator / denominator))
    }
}

struct StableAlertState: Equatable {
    var batteryOverheat = false
    var highLatency = false
    var chipOverheat = false
    var memoryLeak = false
    var extractionFault = false

    var activeKinds: Set<IncidentKind> {
        var result: Set<IncidentKind> = []
        if batteryOverheat { result.insert(.batteryOverheat) }
        if highLatency { result.insert(.networkLatency) }
        if chipOverheat { result.insert(.thermal) }
        if memoryLeak { result.insert(.memoryLeak) }
        if extractionFault { result.insert(.dataSourceFailure) }
        return result
    }
}

final class SustainedAlertFilter {
    private struct Gate {
        var highCount = 0
        var clearCount = 0
        var active = false

        mutating func update(isHigh: Bool, isClear: Bool, required: Int = 3) -> Bool {
            if isHigh {
                highCount += 1
                clearCount = 0
                if highCount >= required { active = true }
            } else if isClear {
                clearCount += 1
                highCount = 0
                if clearCount >= required { active = false }
            }
            return active
        }
    }

    private var battery = Gate()
    private var latency = Gate()
    private var chip = Gate()
    private var extraction = Gate()

    func update(snapshot: HardwareSnapshot, extractionFault: Bool) -> StableAlertState {
        let batteryTemperature = snapshot.batteryMetrics?.temperature
        let latencyValue = snapshot.networkMetrics?.latencyMilliseconds
        let chipTemperature = snapshot.chipTemperature
        return StableAlertState(
            batteryOverheat: battery.update(
                isHigh: batteryTemperature.map { $0 >= 40 } ?? false,
                isClear: batteryTemperature.map { $0 < 38 } ?? true
            ),
            highLatency: latency.update(
                isHigh: latencyValue.map { $0 >= 100 } ?? false,
                isClear: latencyValue.map { $0 < 80 } ?? true
            ),
            chipOverheat: chip.update(
                isHigh: chipTemperature.map { $0 >= 80 } ?? false,
                isClear: chipTemperature.map { $0 < 76 } ?? true
            ),
            memoryLeak: snapshot.memoryLeakAssessment != nil,
            extractionFault: extraction.update(isHigh: extractionFault, isClear: !extractionFault)
        )
    }
}

enum IncidentKind: String, Codable, CaseIterable {
    case thermal = "Thermal"
    case batteryOverheat = "Battery Heat"
    case networkLatency = "Network Latency"
    case memoryLeak = "Memory Growth"
    case dataSourceFailure = "Sensor Failure"
}

struct IncidentMetricPoint: Codable, Equatable {
    let timestamp: Date
    let temperature: Double?
    let fanRPM: Double?
    let cpuUsage: Double?
    let gpuUsage: Double?
    let memoryUsage: Double?
    let batteryTemperature: Double?
    let latencyMilliseconds: Double?
    var appName: String? = nil
    var chipWatts: Double? = nil
}

struct MonitoringIncident: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: IncidentKind
    let startedAt: Date
    var endedAt: Date?
    var points: [IncidentMetricPoint]

    var peakSummary: String {
        switch kind {
        case .thermal:
            return points.compactMap(\.temperature).max().map { String(format: "Peak %.0f°C", $0) } ?? "Temperature unavailable"
        case .batteryOverheat:
            return points.compactMap(\.batteryTemperature).max().map { String(format: "Peak %.1f°C", $0) } ?? "Temperature unavailable"
        case .networkLatency:
            return points.compactMap(\.latencyMilliseconds).max().map { String(format: "Peak %.0f ms", $0) } ?? "Latency unavailable"
        case .memoryLeak:
            return points.compactMap(\.memoryUsage).max().map { String(format: "Peak %.0f%% memory", $0 * 100) } ?? "Memory unavailable"
        case .dataSourceFailure:
            return "Monitoring recovered automatically"
        }
    }
}

final class IncidentRecorder {
    private struct ActiveIncident {
        var incident: MonitoringIncident
        var clearedAt: Date?
    }

    private static let preRoll: TimeInterval = 120
    private static let postRoll: TimeInterval = 120
    private static let maximumIncidents = 20
    private let storageURL: URL?
    private var prebuffer: [IncidentMetricPoint] = []
    private var active: [IncidentKind: ActiveIncident] = [:]
    private(set) var incidents: [MonitoringIncident] = []

    init(storageURL: URL? = IncidentRecorder.defaultStorageURL) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let decoded = try? PropertyListDecoder().decode([MonitoringIncident].self, from: data) {
            incidents = decoded
        }
    }

    func record(snapshot: HardwareSnapshot, alerts: StableAlertState) {
        let now = snapshot.timestamp
        let point = IncidentMetricPoint(
            timestamp: now,
            temperature: snapshot.chipTemperature,
            fanRPM: StatusDashboardView.averageFanRPM(snapshot.fanRPM),
            cpuUsage: snapshot.cpuUsage,
            gpuUsage: snapshot.gpuMetrics?.usage,
            memoryUsage: snapshot.memoryUsage,
            batteryTemperature: snapshot.batteryMetrics?.temperature,
            latencyMilliseconds: snapshot.networkMetrics?.latencyMilliseconds,
            appName: snapshot.topApps.max(by: { $0.energyImpact < $1.energyImpact })?.name,
            chipWatts: snapshot.powerMetrics.flatMap { power in
                guard let cpu = power.cpuWatts, let gpu = power.gpuWatts else { return nil }
                return cpu + gpu
            }
        )
        prebuffer.append(point)
        prebuffer.removeAll { now.timeIntervalSince($0.timestamp) > Self.preRoll }

        let activeKinds = alerts.activeKinds
        for kind in IncidentKind.allCases {
            if activeKinds.contains(kind) {
                if active[kind] == nil {
                    active[kind] = ActiveIncident(
                        incident: MonitoringIncident(
                            id: UUID(),
                            kind: kind,
                            startedAt: now,
                            endedAt: nil,
                            points: prebuffer
                        ),
                        clearedAt: nil
                    )
                } else {
                    active[kind]?.clearedAt = nil
                    active[kind]?.incident.points.append(point)
                }
            } else if var current = active[kind] {
                if current.clearedAt == nil { current.clearedAt = now }
                current.incident.points.append(point)
                if let clearedAt = current.clearedAt, now.timeIntervalSince(clearedAt) >= Self.postRoll {
                    current.incident.endedAt = now
                    incidents.insert(current.incident, at: 0)
                    incidents = Array(incidents.prefix(Self.maximumIncidents))
                    active.removeValue(forKey: kind)
                    persist()
                } else {
                    active[kind] = current
                }
            }
        }
        for kind in Array(active.keys) {
            guard var current = active[kind], current.incident.points.count > 600 else { continue }
            let count = current.incident.points.count
            // Retain a bounded, evenly sampled record even for a long incident.
            current.incident.points = current.incident.points.enumerated()
                .filter { $0.offset % 2 == 0 || $0.offset == count - 1 }.map(\.element)
            active[kind] = current
        }
    }

    var visibleIncidents: [MonitoringIncident] {
        let running = active.values.map(\.incident).sorted { $0.startedAt > $1.startedAt }
        return running + incidents
    }

    func flush() { persist() }

    private func persist() {
        guard let storageURL,
              let data = try? PropertyListEncoder().encode(incidents)
        else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    private static var defaultStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ThermoBar", isDirectory: true)
            .appendingPathComponent("incidents-v1.plist")
    }
}

struct SmartRuleDecision: Equatable {
    let profile: FanResponseProfile
    let reason: String
}

enum SmartRuleEngine {
    static func decide(snapshot: HardwareSnapshot, prediction: ThermalPrediction?, date: Date = Date()) -> SmartRuleDecision {
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical
            || snapshot.chipTemperature.map({ $0 >= 78 }) == true
            || prediction?.minutesTo80.map({ $0 <= 5 }) == true {
            return SmartRuleDecision(profile: .cool, reason: "thermal demand")
        }
        let heavyWorkload = (snapshot.cpuUsage ?? 0) >= 0.70
            || (snapshot.gpuMetrics?.usage ?? 0) >= 0.65
            || snapshot.topApps.first.map { $0.energyImpact >= 45 } == true
        if heavyWorkload, snapshot.batteryMetrics?.powerSource != "Battery" {
            return SmartRuleDecision(profile: .cool, reason: "active workload")
        }
        if snapshot.batteryMetrics?.powerSource == "Battery" {
            return SmartRuleDecision(profile: .quiet, reason: "on battery")
        }
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 22 || hour < 7 {
            return SmartRuleDecision(profile: .quiet, reason: "quiet hours")
        }
        return SmartRuleDecision(profile: .balanced, reason: "normal use")
    }
}

enum DiagnosticReportBuilder {
    static func make(
        snapshot: HardwareSnapshot?,
        mode: MonitoringMode,
        prediction: ThermalPrediction?,
        incidents: [MonitoringIncident],
        fanState: FanControlViewState
    ) -> String {
        var lines = [
            "# MyBar Diagnostic Report",
            "",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Monitoring mode: \(mode.rawValue)",
            "Fan helper: \(fanState.helperReady ? "Ready" : "Unavailable")",
            "Fan mode: \(fanState.activeMode.displayName)",
        ]
        if let snapshot {
            lines += [
                "Temperature: \(snapshot.chipTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable")",
                "CPU: \(snapshot.cpuUsage.map { String(format: "%.1f%%", $0 * 100) } ?? "Unavailable")",
                "GPU: \(snapshot.gpuMetrics.map { String(format: "%.1f%%", $0.usage * 100) } ?? "Unavailable")",
                "Memory pressure: \(snapshot.memoryPressure.displayName)",
                "Fans: \(snapshot.fanRPM.map { $0.map { String(format: "%.0f RPM", $0) } ?? "Unavailable" }.joined(separator: ", "))",
                "Temperature sensors: \(snapshot.respondingTemperatureSensors)/\(snapshot.discoveredTemperatureSensors)",
                "Thermal state: \(String(describing: snapshot.thermalState))",
            ]
        }
        if let prediction { lines.append("Thermal prediction: \(prediction.summary)") }
        lines += ["", "Recent incidents: \(incidents.count)"]
        for incident in incidents.prefix(10) {
            lines.append("- \(incident.kind.rawValue), \(incident.peakSummary), \(ISO8601DateFormatter().string(from: incident.startedAt))")
        }
        lines += [
            "",
            "Privacy: This report contains no file names, document contents, browsing history, or network payloads.",
        ]
        return lines.joined(separator: "\n")
    }
}

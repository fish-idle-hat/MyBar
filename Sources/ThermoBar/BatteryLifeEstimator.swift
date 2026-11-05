import Foundation

struct BatteryHistoryPoint: Codable {
    let timestamp: Date
    let level: Double
}

enum BatteryEstimateConfidence: String {
    case learning
    case adaptive
}

struct BatteryLifeEstimate {
    let minutesRemaining: Double?
    let confidence: BatteryEstimateConfidence
    let history: [BatteryHistoryPoint]
}

/// Learns discharge rates by hour of day and dominant app, while weighting recent use most heavily.
final class BatteryLifeEstimator {
    private struct Average: Codable {
        var watts: Double
        var samples: Int

        mutating func add(_ value: Double) {
            let retained = min(samples, 120)
            watts = (watts * Double(retained) + value) / Double(retained + 1)
            samples = min(121, samples + 1)
        }
    }

    private struct StoredModel: Codable {
        var recentWatts: Double?
        var dischargeSamples = 0
        var hourly: [String: Average] = [:]
        var apps: [String: Average] = [:]
        var history: [BatteryHistoryPoint] = []
    }

    private static let storageKey = "ThermoBar.BatteryLifeModel.v1"
    private let defaults: UserDefaults
    private var model: StoredModel
    private var lastLearningUpdate: Date?
    private var lastPersist: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredModel.self, from: data) {
            self.model = decoded
        } else {
            self.model = StoredModel()
        }
    }

    func update(
        level: Double,
        remainingEnergyWh: Double?,
        dischargeWatts: Double?,
        isCharging: Bool,
        systemMinutesRemaining: Double?,
        topApps: [TopAppMetrics],
        at date: Date
    ) -> BatteryLifeEstimate {
        recordHistory(level: level, at: date)

        if !isCharging, let watts = dischargeWatts, (0.25...250).contains(watts) {
            learn(watts: watts, topApps: topApps, at: date)
        }

        let estimate = isCharging ? nil : estimatedMinutes(
            remainingEnergyWh: remainingEnergyWh,
            currentWatts: dischargeWatts,
            systemMinutes: systemMinutesRemaining,
            topApps: topApps,
            at: date
        )
        persistIfNeeded(at: date)
        return BatteryLifeEstimate(
            minutesRemaining: estimate,
            confidence: model.dischargeSamples >= 60 ? .adaptive : .learning,
            history: recentHistory(at: date, currentLevel: level)
        )
    }

    private func learn(watts: Double, topApps: [TopAppMetrics], at date: Date) {
        guard lastLearningUpdate.map({ date.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastLearningUpdate = date
        model.recentWatts = model.recentWatts.map { $0 * 0.82 + watts * 0.18 } ?? watts
        model.dischargeSamples += 1

        let hourKey = String(Calendar.current.component(.hour, from: date))
        model.hourly[hourKey, default: Average(watts: watts, samples: 0)].add(watts)
        for app in topApps.prefix(3) {
            model.apps[app.name, default: Average(watts: watts, samples: 0)].add(watts)
        }
    }

    private func estimatedMinutes(
        remainingEnergyWh: Double?,
        currentWatts: Double?,
        systemMinutes: Double?,
        topApps: [TopAppMetrics],
        at date: Date
    ) -> Double? {
        guard let energy = remainingEnergyWh, energy > 0 else { return systemMinutes }
        var weightedRates: [(watts: Double, weight: Double)] = []

        if let currentWatts, (0.25...250).contains(currentWatts) {
            weightedRates.append((currentWatts, 0.25))
        }
        if let recent = model.recentWatts, (0.25...250).contains(recent) {
            weightedRates.append((recent, 0.35))
        }

        let hourKey = String(Calendar.current.component(.hour, from: date))
        if let hourly = model.hourly[hourKey], hourly.samples >= 3 {
            weightedRates.append((hourly.watts, 0.15))
        }

        let appRates = topApps.prefix(3).compactMap { model.apps[$0.name] }.filter { $0.samples >= 3 }
        if !appRates.isEmpty {
            weightedRates.append((appRates.map(\.watts).reduce(0, +) / Double(appRates.count), 0.25))
        }

        if let systemMinutes, systemMinutes > 0 {
            let nativeRate = energy / (systemMinutes / 60)
            weightedRates.append((nativeRate, model.dischargeSamples < 60 ? 0.40 : 0.10))
        }

        let totalWeight = weightedRates.map(\.weight).reduce(0, +)
        guard totalWeight > 0 else { return systemMinutes }
        let predictedWatts = weightedRates.reduce(0) { $0 + $1.watts * $1.weight } / totalWeight
        guard predictedWatts > 0 else { return systemMinutes }
        return min(72 * 60, max(0, energy / predictedWatts * 60))
    }

    private func recordHistory(level: Double, at date: Date) {
        let shouldAppend = model.history.last.map {
            date.timeIntervalSince($0.timestamp) >= 300 || abs(level - $0.level) >= 0.005
        } ?? true
        guard shouldAppend else { return }
        model.history.append(BatteryHistoryPoint(timestamp: date, level: level))
        let cutoff = date.addingTimeInterval(-24 * 60 * 60)
        model.history.removeAll { $0.timestamp < cutoff }
    }

    private func recentHistory(at date: Date, currentLevel: Double) -> [BatteryHistoryPoint] {
        let cutoff = date.addingTimeInterval(-6 * 60 * 60)
        var points = model.history.filter { $0.timestamp >= cutoff }
        if points.last.map({ date.timeIntervalSince($0.timestamp) > 30 }) ?? true {
            points.append(BatteryHistoryPoint(timestamp: date, level: currentLevel))
        }
        return points
    }

    private func persistIfNeeded(at date: Date) {
        guard lastPersist.map({ date.timeIntervalSince($0) >= 60 }) ?? true,
              let data = try? JSONEncoder().encode(model)
        else { return }
        defaults.set(data, forKey: Self.storageKey)
        lastPersist = date
    }
}

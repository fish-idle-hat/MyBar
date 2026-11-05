import Foundation

/// Small, context-specific temperature distributions; one sample per minute.
final class PersonalBaseline {
    struct Range: Equatable {
        let context: String
        let low: Double
        let high: Double
        let count: Int
        let watts: ClosedRange<Double>?
        let rpm: ClosedRange<Double>?
    }
    private let defaults: UserDefaults
    private var samples: [String: [Double]]
    private var lastSample = Date.distantPast
    private var lastSave = Date.distantPast
    private(set) var current: Range?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        samples = (defaults.dictionary(forKey: "ThermoBar.PersonalBaseline.v1") as? [String: [Double]] ?? [:])
            .mapValues { Array($0.filter { $0.isFinite && $0 >= 0 && $0 <= 20_000 }.suffix(240)) }
    }

    func update(_ snapshot: HardwareSnapshot) {
        let workload = (snapshot.gpuMetrics?.usage ?? 0) > 0.4 ? "GPU work"
            : (snapshot.cpuUsage ?? 0) > 0.4 ? "CPU work" : "Light use"
        let power = snapshot.batteryMetrics?.isCharging == true ? "Charging"
            : snapshot.batteryMetrics?.powerSource == "Battery" ? "Battery"
            : snapshot.batteryMetrics == nil ? "Unknown power" : "AC"
        let context = "\(workload) · \(power)"
        let values = (samples[context] ?? []).sorted()
        func typical(_ key: String) -> ClosedRange<Double>? {
            let values = (samples[key] ?? []).sorted()
            guard values.count >= 20 else { return nil }
            return values[Int(Double(values.count - 1) * 0.1)]...values[Int(Double(values.count - 1) * 0.9)]
        }
        current = values.count >= 20 ? Range(
            context: context, low: values[Int(Double(values.count - 1) * 0.1)],
            high: values[Int(Double(values.count - 1) * 0.9)], count: values.count,
            watts: typical(context + "|watts"), rpm: typical(context + "|rpm")
        ) : nil
        guard snapshot.timestamp.timeIntervalSince(lastSample) >= 60,
              let temperature = snapshot.chipTemperature, temperature.isFinite,
              temperature > 0, temperature < 120 else { return }
        lastSample = snapshot.timestamp
        samples[context, default: []].append(temperature)
        samples[context] = Array(samples[context, default: []].suffix(240))
        func append(_ value: Double?, suffix: String) {
            guard let value, value.isFinite, value >= 0, value <= 20_000 else { return }
            let key = context + suffix
            samples[key, default: []].append(value)
            samples[key] = Array(samples[key, default: []].suffix(240))
        }
        let watts = snapshot.powerMetrics.flatMap { power -> Double? in
            guard let cpu = power.cpuWatts, let gpu = power.gpuWatts else { return nil }
            return cpu + gpu
        }
        append(watts, suffix: "|watts")
        append(StatusDashboardView.averageFanRPM(snapshot.fanRPM), suffix: "|rpm")
        if snapshot.timestamp.timeIntervalSince(lastSave) >= 300 {
            flush()
            lastSave = snapshot.timestamp
        }
    }

    func flush() { defaults.set(samples, forKey: "ThermoBar.PersonalBaseline.v1") }
}

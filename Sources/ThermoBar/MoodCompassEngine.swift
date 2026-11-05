import Foundation

enum CompassMetric: String, CaseIterable, Codable {
    case mood, energy, stress, readiness
    var title: String { switch self {
    case .mood: "Mood balance"
    case .energy: "Energy"
    case .stress: "Stress load"
    case .readiness: "Focus readiness"
    } }
}

enum CompassSignal: String, CaseIterable, Codable {
    case activity, typing, rhythm, switching, streak, breaks, music, calendar, tasks, daylight, hourSin, hourCos
    case contextHome, contextWork, contextTravel, contextRest
}

struct CompassSettings: Codable, Equatable {
    var enabled = false
    var activity = true
    var typing = false
    var music = false
    var calendar = false
    var reminders = false
    var daylight = false
    var context = "Unspecified"
}

struct CompassObservation {
    var timestamp: Date
    var seconds: Double
    var signals: [String: Double]
    // Missing/revoked/secure-input data stays missing, never a measured zero.
    var isValid: Bool {
        seconds.isFinite && seconds > 0 && seconds <= 120 && !signals.isEmpty
            && signals.allSatisfy { CompassSignal(rawValue: $0.key) != nil && $0.value.isFinite && (0...1).contains($0.value) }
    }
}

struct CompassBaseline: Codable {
    var mean: Double
    var variance: Double = 0.04
    var count: Int = 1
    mutating func update(_ value: Double) {
        // Slow, bounded adaptation: a single unusual minute cannot move the baseline far.
        let alpha = count < 60 ? 1 / Double(count + 1) : 0.002
        let delta = max(-0.3, min(0.3, value - mean))
        mean += alpha * delta
        variance = max(0.0025, (1 - alpha) * variance + alpha * delta * delta)
        count = min(100_000, count + 1)
    }
}

struct CompassModel: Codable, Equatable {
    var version = 1
    var bias: [String: Double] = ["mood": 50, "energy": 62, "stress": 35, "readiness": 62]
    var weights: [String: [String: Double]] = [
        "mood": [:],
        "energy": ["streak": -22, "breaks": 16, "daylight": 5],
        "stress": ["switching": 20, "streak": 22, "breaks": -16, "calendar": 12],
        "readiness": ["switching": -18, "streak": -18, "breaks": 16, "calendar": -8],
    ]
    func predict(_ features: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: CompassMetric.allCases.map { metric in
            (metric.rawValue, predict(metric, features: features))
        })
    }
    fileprivate func predict(_ metric: CompassMetric, features: [String: Double]) -> Double {
        let value = (bias[metric.rawValue] ?? 50) + (weights[metric.rawValue] ?? [:]).reduce(0) {
            $0 + $1.value * ((features[$1.key] ?? 0.5) - 0.5)
        }
        return max(0, min(100, value))
    }
    var isValid: Bool {
        Set(bias.keys) == Set(CompassMetric.allCases.map(\.rawValue))
            && bias.values.allSatisfy { $0.isFinite && (0...100).contains($0) }
            && weights.allSatisfy { CompassMetric(rawValue: $0.key) != nil && $0.value.allSatisfy { CompassSignal(rawValue: $0.key) != nil && $0.value.isFinite && abs($0.value) <= 40 } }
    }
}

struct CompassPoint: Codable {
    var timestamp: Date
    var values: [String: Double]
    var count: Int = 1
}

struct CompassLabel: Codable {
    let timestamp: Date
    let features: [String: Double]
    let actual: [String: Double]
    let predicted: [String: Double]
    let modelVersion: Int
    let quality: Double
    let kind: String
}

struct CompassReview: Codable {
    let timestamp: Date
    let version: Int
    let outcome: String
    let detail: String
}

struct CompassGuard: Codable {
    let previous: CompassModel
    let activatedAt: Date
}

struct CompassFocusSession: Codable {
    let startedAt: Date
    let features: [String: Double]
    let predicted: [String: Double]
    let modelVersion: Int
    let quality: Double
}

struct CompassState: Codable {
    var schema = 1
    var model = CompassModel()
    var baseline: [String: CompassBaseline] = [:]
    var points: [CompassPoint] = []
    var days: [CompassPoint] = []
    var labels: [CompassLabel] = []
    var reviews: [CompassReview] = []
    var previousModels: [CompassModel] = []
    var guardrail: CompassGuard?
    var reviewAnchor: Date?
    var observedDays: [String] = []
    var latestFeatures: [String: Double] = [:]
    var latestRaw: [String: Double] = [:]
    var latestEstimate: [String: Double] = [:]
    var latestDate: Date?
    var latestQuality = 0.0
    var focusSession: CompassFocusSession?
    var hasData: Bool {
        !baseline.isEmpty || !points.isEmpty || !days.isEmpty || !labels.isEmpty || !reviews.isEmpty || focusSession != nil
    }
    var isValid: Bool {
        func features(_ values: [String: Double]) -> Bool {
            values.allSatisfy { CompassSignal(rawValue: $0.key) != nil && $0.value.isFinite && (0...1).contains($0.value) }
        }
        func scores(_ values: [String: Double]) -> Bool {
            values.allSatisfy { CompassMetric(rawValue: $0.key) != nil && $0.value.isFinite && (0...100).contains($0.value) }
        }
        return schema == 1 && model.isValid && previousModels.allSatisfy(\.isValid)
            && (guardrail?.previous.isValid ?? true)
            && points.count <= 2_017 && days.count <= 180 && labels.count <= 512 && reviews.count <= 104
            && baseline.allSatisfy { CompassSignal(rawValue: $0.key) != nil && $0.value.mean.isFinite && (0...1).contains($0.value.mean) && $0.value.variance.isFinite && $0.value.variance > 0 && $0.value.count > 0 }
            && features(latestFeatures) && features(latestRaw) && scores(latestEstimate)
            && latestQuality.isFinite && (0...1).contains(latestQuality)
            && (latestDate?.timeIntervalSince1970.isFinite ?? true)
            && (points + days).allSatisfy { $0.timestamp.timeIntervalSince1970.isFinite && $0.count > 0 && scores($0.values) }
            && labels.allSatisfy { $0.timestamp.timeIntervalSince1970.isFinite && features($0.features) && !$0.actual.isEmpty && scores($0.actual) && scores($0.predicted) && $0.quality.isFinite && (0...1).contains($0.quality) }
            && (focusSession.map { features($0.features) && scores($0.predicted) && $0.quality.isFinite && (0...1).contains($0.quality) } ?? true)
    }
}

struct CompassPresentation {
    var settings = CompassSettings()
    var state = CompassState()
    var permissions: [String: String] = [:]
    var message = "Private by default. Enable local tracking to begin."
    var moodIsCalibrated: Bool { state.model.version > 1 && state.labels.filter { $0.actual["mood"] != nil }.count >= 24 }
    var recommendation: String {
        guard settings.enabled else { return "Choose which signals you want to share on this Mac. Nothing is uploaded." }
        guard let date = state.latestDate, Date().timeIntervalSince(date) < 600 else { return "Waiting for a fresh sample. Sleep, lock time and data gaps are not interpreted as mood." }
        guard state.latestQuality >= 0.4 else { return "Not enough approved behavioural signals for a useful estimate. Enable activity or additional sources in Privacy." }
        let raw = state.latestRaw
        if raw["activity"] == 0 { return "The last sample was input-idle: that could be reading, a meeting or a break. It does not reveal your mood." }
        if (raw["streak"] ?? 0) >= 0.65 { return "A long active stretch: try a 3–5 minute screen break, then check how you feel." }
        if (state.latestEstimate["stress"] ?? 0) >= 65 { return "Signals suggest higher load. Try one task at a time or a short pause; this is not a stress diagnosis." }
        if let switching = raw["switching"], let base = state.baseline["switching"], base.count > 60, switching > base.mean + 0.15 {
            return "More app switching than your usual baseline. A short single-task block may help."
        }
        if (state.latestEstimate["readiness"] ?? 0) >= 60 { return "A possible focus window: try 20 minutes on one task, then rate how the session went." }
        return "Consider a lighter task or a short break. Your own check-in matters more than these estimates."
    }
    var confidenceText: String {
        let labels = state.labels.filter { $0.kind == "check-in" }.count
        if !settings.enabled { return "Monitoring off" }
        if state.latestDate == nil { return "Collecting first minute" }
        if state.model.version == 1 { return "Experimental · learning baseline · \(labels) check-ins" }
        return "Experimental · personalized v\(state.model.version) · \(state.guardrail == nil ? "feedback reviewed" : "provisional update")"
    }
}

/// A small menu-bar payload, not a copy of the trend/feedback history.
struct CompassMenuReadiness {
    var enabled = false
    var sampledAt: Date?
    var estimate: Double?
    var quality = 0.0
    var baselineSamples = 0

    init() {}
    init(_ presentation: CompassPresentation) {
        enabled = presentation.settings.enabled
        sampledAt = presentation.state.latestDate
        estimate = presentation.state.latestEstimate["readiness"]
        let settings = presentation.settings
        var approved: Set<String> = []
        if settings.activity { approved.formUnion(["activity", "switching", "streak", "breaks"]) }
        if settings.typing { approved.formUnion(["typing", "rhythm"]) }
        if settings.music { approved.insert("music") }
        if settings.calendar { approved.insert("calendar") }
        if settings.reminders { approved.insert("tasks") }
        if settings.daylight { approved.insert("daylight") }
        let available = presentation.state.latestRaw.keys.filter { approved.contains($0) }
        quality = min(presentation.state.latestQuality, Double(available.count) / 5)
        baselineSamples = available.compactMap { presentation.state.baseline[$0]?.count }.max() ?? 0
    }

    func percentage(at now: Date) -> Int? {
        guard enabled, let sampledAt, (0...180).contains(now.timeIntervalSince(sampledAt)),
              quality.isFinite, quality >= 0.4, baselineSamples >= 20,
              let estimate, estimate.isFinite, (0...100).contains(estimate) else { return nil }
        // Avoid pretending an experimental behavioural estimate is precise to 1%.
        return Int((estimate / 5).rounded()) * 5
    }

    func explanation(at now: Date) -> String {
        if !enabled { return "Readiness unavailable: start Mood Compass to opt in." }
        guard let sampledAt, (0...180).contains(now.timeIntervalSince(sampledAt)) else {
            return "Readiness unavailable: waiting for fresh behavioural data."
        }
        guard quality.isFinite, quality >= 0.4 else { return "Readiness unavailable: insufficient approved signals." }
        guard baselineSamples >= 20 else { return "Readiness learning: \(baselineSamples)/20 baseline samples (about 20 observed minutes)." }
        guard let value = percentage(at: now) else { return "Readiness unavailable: invalid estimate." }
        return "Estimated focus readiness about \(value)/100. Experimental, not a measured emotion or medical recovery score."
    }
}

/// Deterministic, bounded local learner. Owned by a utility queue, not the UI.
final class MoodCompassEngine {
    private(set) var state: CompassState
    init(state: CompassState = CompassState()) {
        self.state = state.isValid ? state : CompassState()
    }

    static func dayKey(_ date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    @discardableResult
    func observe(_ observation: CompassObservation) -> Bool {
        guard observation.isValid,
              state.latestDate.map({ observation.timestamp > $0 }) ?? true else { return false }
        let features = observation.signals.mapValues { $0 }
        state.latestRaw = features
        // Express behaviour relative to the individual's slowly adapting baseline.
        state.latestFeatures = Dictionary(uniqueKeysWithValues: features.map { key, value in
            guard let base = state.baseline[key], base.count >= 20,
                  key != "hourSin", key != "hourCos", key != "daylight", !key.hasPrefix("context") else { return (key, value) }
            return (key, max(0, min(1, 0.5 + (value - base.mean) / max(0.15, sqrt(base.variance)) * 0.12)))
        })
        state.latestEstimate = state.model.predict(state.latestFeatures)
        state.latestDate = observation.timestamp
        state.latestQuality = min(1, Double(features.keys.filter { !["hourSin", "hourCos"].contains($0) && !$0.hasPrefix("context") }.count) / 5)
        for (key, value) in features {
            if state.baseline[key] == nil { state.baseline[key] = CompassBaseline(mean: value) }
            else { state.baseline[key]?.update(value) }
        }
        let day = Self.dayKey(observation.timestamp)
        if state.latestQuality >= 0.4 {
            if !state.observedDays.contains(day) { state.observedDays.append(day) }
            if state.reviewAnchor == nil { state.reviewAnchor = observation.timestamp }
            var values = state.latestEstimate
            if state.model.version == 1 || state.labels.filter({ $0.actual["mood"] != nil }).count < 24 { values.removeValue(forKey: "mood") }
            aggregate(&state.points, date: observation.timestamp, seconds: 300, values: values)
            aggregate(&state.days, date: observation.timestamp, seconds: 86_400, values: values)
        }
        trim(at: observation.timestamp)
        reviewIfDue(at: observation.timestamp)
        return true
    }

    private func aggregate(_ points: inout [CompassPoint], date: Date, seconds: Double, values: [String: Double]) {
        let bucket = seconds == 86_400 ? Calendar.current.startOfDay(for: date)
            : Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / seconds) * seconds)
        if points.last?.timestamp == bucket {
            let index = points.count - 1
            let count = points[index].count
            for (key, value) in values {
                points[index].values[key] = ((points[index].values[key] ?? value) * Double(count) + value) / Double(count + 1)
            }
            points[index].count += 1
        } else { points.append(CompassPoint(timestamp: bucket, values: values)) }
    }

    @discardableResult
    func checkIn(_ ratings: [String: Double], at date: Date, kind: String = "check-in") -> Bool {
        guard let sampledAt = state.latestDate, (0...600).contains(date.timeIntervalSince(sampledAt)),
              !ratings.isEmpty, ratings.allSatisfy({ CompassMetric(rawValue: $0.key) != nil && $0.value.isFinite && (0...100).contains($0.value) }),
              state.labels.last.map({ date.timeIntervalSince($0.timestamp) >= 300 }) ?? true
        else { return false }
        state.labels.append(CompassLabel(timestamp: date, features: state.latestFeatures, actual: ratings,
            predicted: state.latestEstimate, modelVersion: state.model.version, quality: state.latestQuality, kind: kind))
        validateGuardrail(at: date)
        trim(at: date)
        return true
    }

    func meanAbsoluteError() -> Double? {
        let recent = state.labels.suffix(50)
        let errors = recent.flatMap { label in label.actual.compactMap { key, value in label.predicted[key].map { abs($0 - value) } } }
        return errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
    }

    func beginFocus(at date: Date) -> Bool {
        guard let sampledAt = state.latestDate, (0...600).contains(date.timeIntervalSince(sampledAt)) else { return false }
        state.focusSession = CompassFocusSession(startedAt: date, features: state.latestFeatures,
            predicted: state.latestEstimate, modelVersion: state.model.version, quality: state.latestQuality)
        return true
    }

    func finishFocus(score: Double, at date: Date) -> Bool {
        guard let session = state.focusSession, (300...7_200).contains(date.timeIntervalSince(session.startedAt)),
              score.isFinite, (0...100).contains(score) else { return false }
        state.labels.append(CompassLabel(timestamp: date, features: session.features, actual: ["readiness": score],
            predicted: session.predicted, modelVersion: session.modelVersion, quality: session.quality, kind: "focus outcome"))
        state.focusSession = nil
        validateGuardrail(at: date)
        trim(at: date)
        return true
    }

    func reviewIfDue(at date: Date) {
        guard let anchor = state.reviewAnchor, date.timeIntervalSince(anchor) >= 7 * 86_400,
              state.observedDays.count >= 7 else { return }
        defer { state.reviewAnchor = date; state.observedDays = [] }
        let labels = state.labels.filter { $0.quality >= 0.4 && date.timeIntervalSince($0.timestamp) <= 56 * 86_400 }
        guard labels.count >= 32, Set(labels.map { Self.dayKey($0.timestamp) }).count >= 4 else {
            log(date, "Held steady", "Reviewed seven observed days. Need 32 reliable outcomes across 4 days before changing weights.")
            return
        }
        guard state.guardrail == nil else {
            log(date, "Held steady", "Waiting for fresh outcomes to validate the previous adjustment.")
            return
        }
        let split = labels.count * 3 / 4
        let training = Array(labels.prefix(split)), validation = Array(labels.suffix(from: split))
        var candidate = state.model
        let trainable = CompassMetric.allCases.compactMap { metric -> (CompassMetric, [CompassLabel])? in
            let matching = training.filter { $0.actual[metric.rawValue] != nil }
            guard matching.count >= 16, validation.filter({ $0.actual[metric.rawValue] != nil }).count >= 4 else { return nil }
            return (metric, matching)
        }
        // Small regularized updates; only real check-ins/outcomes are targets.
        for _ in 0..<60 {
            for (metric, matching) in trainable {
                let key = metric.rawValue
                let residuals = matching.map { (label: $0, error: candidate.predict(metric, features: $0.features) - $0.actual[key]!) }
                let biasGradient = residuals.reduce(0) { $0 + $1.error } / Double(matching.count)
                let originalBias = state.model.bias[key] ?? 50
                candidate.bias[key] = max(0, min(100, max(originalBias - 5, min(originalBias + 5, (candidate.bias[key] ?? 50) - 0.08 * biasGradient))))
                for signal in CompassSignal.allCases {
                    let name = signal.rawValue
                    let old = state.model.weights[key]?[name] ?? 0
                    let current = candidate.weights[key]?[name] ?? 0
                    let gradient = residuals.reduce(0) { $0 + $1.error * (($1.label.features[name] ?? 0.5) - 0.5) } / Double(matching.count)
                    candidate.weights[key, default: [:]][name] = max(-40, min(40, max(old - 3, min(old + 3, current - 0.08 * (gradient + 0.05 * current)))))
                }
            }
        }
        let oldError = Self.error(state.model, labels: validation), newError = Self.error(candidate, labels: validation)
        let noHarm = CompassMetric.allCases.allSatisfy {
            Self.error(candidate, labels: validation, metric: $0.rawValue) <= Self.error(state.model, labels: validation, metric: $0.rawValue) + 2
        }
        guard candidate.isValid, oldError.isFinite, newError <= oldError - max(1, oldError * 0.03), noHarm else {
            log(date, "Rejected", "Candidate did not improve chronological holdout outcomes safely. Previous model retained.")
            return
        }
        state.guardrail = CompassGuard(previous: state.model, activatedAt: date)
        state.previousModels.append(state.model)
        candidate.version = max(state.model.version, state.reviews.map(\.version).max() ?? 0) + 1
        state.model = candidate
        log(date, "Provisional update", String(format: "Holdout error %.1f → %.1f points. Monitoring fresh outcomes before confirming.", oldError, newError))
    }

    private func validateGuardrail(at date: Date) {
        guard let guardrail = state.guardrail else { return }
        let fresh = state.labels.filter { $0.timestamp > guardrail.activatedAt && $0.quality >= 0.4 }
        guard fresh.count >= 8, Set(fresh.map { Self.dayKey($0.timestamp) }).count >= 2 else { return }
        let changed = CompassMetric.allCases.filter {
            state.model.bias[$0.rawValue] != guardrail.previous.bias[$0.rawValue]
                || state.model.weights[$0.rawValue] != guardrail.previous.weights[$0.rawValue]
        }
        guard changed.allSatisfy({ metric in fresh.filter { $0.actual[metric.rawValue] != nil }.count >= 8 }) else { return }
        let current = Self.error(state.model, labels: fresh), previous = Self.error(guardrail.previous, labels: fresh)
        let harmedMetric = changed.contains {
            Self.error(state.model, labels: fresh, metric: $0.rawValue) > Self.error(guardrail.previous, labels: fresh, metric: $0.rawValue) * 1.1 + 2
        }
        if current > previous * 1.1 + 2 || harmedMetric {
            state.model = guardrail.previous
            log(date, "Rolled back", "Fresh outcomes worsened against the previous configuration. Restored the previous model automatically.")
        } else {
            log(date, "Confirmed", "Fresh outcomes passed the regression guard. This does not prove emotional accuracy.")
        }
        state.guardrail = nil
    }

    static func error(_ model: CompassModel, labels: [CompassLabel], metric: String? = nil) -> Double {
        let errors = labels.flatMap { label in
            label.actual.compactMap { key, value -> Double? in
                guard metric == nil || metric == key else { return nil }
                return abs((model.predict(label.features)[key] ?? 50) - value)
            }
        }
        return errors.isEmpty ? .infinity : errors.reduce(0, +) / Double(errors.count)
    }

    private func log(_ date: Date, _ outcome: String, _ detail: String) {
        state.reviews.append(CompassReview(timestamp: date, version: state.model.version, outcome: outcome, detail: detail))
    }
    private func trim(at date: Date) {
        state.points = Array(state.points.filter { date.timeIntervalSince($0.timestamp) <= 7 * 86_400 }.suffix(2_017))
        state.days = Array(state.days.suffix(180))
        state.labels = Array(state.labels.filter { date.timeIntervalSince($0.timestamp) <= 180 * 86_400 }.suffix(512))
        state.reviews = Array(state.reviews.suffix(104))
        state.previousModels = Array(state.previousModels.suffix(8))
    }
}

enum CompassStorage {
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ThermoBar/MoodCompass/state-v1.plist")
    }
    static func load(from url: URL) throws -> CompassState {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 < 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let state = try PropertyListDecoder().decode(CompassState.self, from: Data(contentsOf: url))
        guard state.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }
    static func save(_ state: CompassState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(state).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

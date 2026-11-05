import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import CoreLocation
import EventKit

/// Opt-in collection. All persistent model work is serialized off the main thread.
final class MoodCompassManager: NSObject, CLLocationManagerDelegate {
    var onChange: ((CompassPresentation) -> Void)?
    private static let settingsKey = "TheBar.MoodCompass.Settings.v1"
    private let defaults: UserDefaults
    private let storageURL: URL?
    private let worker = DispatchQueue(label: "TheBar.mood-local-learning", qos: .utility)
    private let contextQueue = DispatchQueue(label: "TheBar.mood-context", qos: .utility)
    private var engine = MoodCompassEngine()
    private var lastSaved = Date.distantPast
    private var storageFailed = false
    private var stateReadable = true
    private(set) var settings: CompassSettings
    private var presentation = CompassPresentation()
    private var timer: Timer?
    private var keyboardTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastSample = Date()
    private var activeSeconds = 0.0
    private var appSwitches = 0
    private var breakCount = 0
    private var wasIdle = false
    private var sessionActive = true
    private var keyCounter: UInt32?
    private var keyBuckets: [Double] = []
    private lazy var events = EKEventStore()
    private var location: CLLocationManager?
    private var contextGeneration = UUID()
    private var lastContextRefresh = Date.distantPast
    private var calendarLoad: (Date, Double)?
    private var taskCompletion: (Date, Double)?
    private var daylight: (Date, Double)?

    init(defaults: UserDefaults = .standard, storageURL: URL? = CompassStorage.defaultURL) {
        self.defaults = defaults
        self.storageURL = storageURL
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? PropertyListDecoder().decode(CompassSettings.self, from: $0) } ?? CompassSettings()
        super.init()
        presentation.settings = settings
        worker.async { [weak self] in
            guard let self else { return }
            if let url = storageURL, FileManager.default.fileExists(atPath: url.path) {
                do { self.engine = MoodCompassEngine(state: try CompassStorage.load(from: url)) }
                catch { self.stateReadable = false }
            }
            self.publish()
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.enabled, self.settings.activity, self.sessionActive else { return }
            self.appSwitches += 1 // No app/window names or bundle identifiers are retained.
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = false; self?.resetWindow()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = true; self?.resetWindow()
            })
        }
        rebuildTimers()
        refreshPresentation()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        keyboardTimer?.invalidate(); keyboardTimer = nil
        location?.stopUpdatingLocation()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        worker.sync { persist(force: true) }
    }

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        persistSettings()
        contextGeneration = UUID()
        resetWindow()
        rebuildTimers()
        refreshPresentation(message: enabled ? "Local estimates only. First sample arrives in about one minute." : "Monitoring paused. Existing history is retained until you delete it.")
    }

    func setSource(_ source: String, enabled: Bool) {
        guard settings.enabled else { return }
        switch source {
        case "activity": settings.activity = enabled
        case "typing": settings.typing = enabled
        case "music": settings.music = enabled
        case "calendar": settings.calendar = enabled
        case "reminders": settings.reminders = enabled
        case "daylight": settings.daylight = enabled
        default: return
        }
        contextGeneration = UUID()
        persistSettings()
        resetWindow()
        rebuildTimers()
        // Authorization requests occur only after the user enables that source.
        if enabled {
            NSApp.activate(ignoringOtherApps: true)
            if source == "typing", !keyboardAllowed { _ = CGRequestListenEventAccess() }
            if source == "calendar" { events.requestFullAccessToEvents { [weak self] _, _ in DispatchQueue.main.async { self?.authorizationChanged() } } }
            if source == "reminders" { events.requestFullAccessToReminders { [weak self] _, _ in DispatchQueue.main.async { self?.authorizationChanged() } } }
            if source == "daylight" {
                if location == nil { location = CLLocationManager(); location?.desiredAccuracy = kCLLocationAccuracyThreeKilometers; location?.delegate = self }
                location?.requestWhenInUseAuthorization()
                requestDaylight()
            }
        } else {
            if source == "calendar" { calendarLoad = nil }
            if source == "reminders" { taskCompletion = nil }
            if source == "daylight" { daylight = nil; location?.stopUpdatingLocation() }
        }
        lastContextRefresh = .distantPast
        refreshPresentation()
    }

    func setContext(_ value: String) {
        guard ["Unspecified", "Home", "Work / study", "Travelling", "Resting"].contains(value) else { return }
        settings.context = value
        persistSettings()
        refreshPresentation()
    }

    func recordCheckIn(_ ratings: [String: Double]) {
        guard settings.enabled else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let saved = self.engine.checkIn(ratings, at: Date())
            self.persist(force: saved)
            self.publish(message: saved ? "Check-in saved locally. Your report takes priority over the estimate." : "Wait for a fresh sample; check-ins are limited to one every five minutes.")
        }
    }

    func beginFocus() {
        guard settings.enabled else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let saved = self.engine.beginFocus(at: Date())
            self.persist(force: saved)
            self.publish(message: saved ? "Focus session started. After five minutes, rate the outcome to teach readiness." : "Wait for a fresh sample before starting a focus session.")
        }
    }

    func finishFocus(_ score: Double) {
        guard settings.enabled else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let saved = self.engine.finishFocus(score: score, at: Date())
            self.persist(force: saved)
            self.publish(message: saved ? "Focus outcome saved against the prediction made when you started." : "Rate a focus session after 5 minutes and within 2 hours.")
        }
    }

    func deleteAllData(completion: (() -> Void)? = nil) {
        setEnabled(false)
        settings = CompassSettings()
        defaults.removeObject(forKey: Self.settingsKey)
        calendarLoad = nil; taskCompletion = nil; daylight = nil
        location?.delegate = nil; location = nil
        let currentSettings = settings
        worker.async { [weak self] in
            guard let self else { return }
            do {
                if let url = self.storageURL, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                self.engine = MoodCompassEngine()
                self.stateReadable = true; self.storageFailed = false
                self.publish(message: "Mood Compass data and learned models deleted. Monitoring is off.", settings: currentSettings)
            } catch { self.publish(message: "Deletion failed. Monitoring is off; try again after checking file permissions.") }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func persistSettings() {
        if let data = try? PropertyListEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private var keyboardAllowed: Bool { CGPreflightListenEventAccess() || AXIsProcessTrusted() }
    private func resetWindow() {
        lastSample = Date(); appSwitches = 0; keyBuckets = []; keyCounter = nil
        activeSeconds = 0; breakCount = 0; wasIdle = false
    }
    private func rebuildTimers() {
        timer?.invalidate(); timer = nil
        keyboardTimer?.invalidate(); keyboardTimer = nil
        guard settings.enabled else { return }
        let sampleTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.sample() }
        sampleTimer.tolerance = 12
        RunLoop.main.add(sampleTimer, forMode: .common); timer = sampleTimer
        if settings.typing {
            let keyTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.sampleKeyboard() }
            keyTimer.tolerance = 2
            RunLoop.main.add(keyTimer, forMode: .common); keyboardTimer = keyTimer
        }
    }

    private func sampleKeyboard() {
        guard settings.enabled, settings.typing, sessionActive, keyboardAllowed else { keyCounter = nil; return }
        let counter = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        defer { keyCounter = counter }
        guard !IsSecureEventInputEnabled(), let previous = keyCounter, counter >= previous else { keyBuckets = []; return }
        let delta = Double(counter - previous)
        // Ignore counter resets and implausible/synthetic bursts, rather than training on them.
        if delta <= 500 { keyBuckets.append(delta) }
        if keyBuckets.count > 12 { keyBuckets.removeFirst() }
    }

    private func sample() {
        guard settings.enabled else { return }
        let now = Date(), seconds = now.timeIntervalSince(lastSample)
        defer { lastSample = now; appSwitches = 0; keyBuckets = [] }
        guard sessionActive, (30...120).contains(seconds) else { resetWindow(); return }
        let hour = Calendar.current.component(.hour, from: now)
        var values = ["hourSin": (sin(Double(hour) * .pi / 12) + 1) / 2,
                      "hourCos": (cos(Double(hour) * .pi / 12) + 1) / 2]
        if settings.activity {
            // Any-input uses the documented UInt32.max sentinel, not a key or mouse-event log.
            let anyIdle = CGEventType(rawValue: UInt32.max).map {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
            } ?? .infinity
            if anyIdle.isFinite {
                let resting = anyIdle >= 120
                if resting { activeSeconds = 0; if !wasIdle { breakCount += 1 } }
                else { activeSeconds += seconds }
                wasIdle = resting
                values["activity"] = resting ? 0 : 1
                values["switching"] = min(1, Double(appSwitches) / max(1, seconds / 60) / 10)
                values["streak"] = min(1, activeSeconds / 7_200)
                values["breaks"] = resting ? 1 : max(0, 1 - activeSeconds / 1_800)
            }
        }
        if settings.typing, keyboardAllowed, !keyBuckets.isEmpty {
            values["typing"] = min(1, keyBuckets.reduce(0, +) / seconds * 60 / 180)
            let mean = keyBuckets.reduce(0, +) / Double(keyBuckets.count)
            values["rhythm"] = mean > 0 ? min(1, sqrt(keyBuckets.reduce(0) { $0 + pow($1 - mean, 2) } / Double(keyBuckets.count)) / mean / 2) : 0
        }
        if settings.calendar, EKEventStore.authorizationStatus(for: .event) == .fullAccess,
           let cached = calendarLoad, now.timeIntervalSince(cached.0) < 1_200 { values["calendar"] = cached.1 }
        if settings.reminders, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
           let cached = taskCompletion, now.timeIntervalSince(cached.0) < 1_200 { values["tasks"] = cached.1 }
        if settings.daylight, locationAuthorized, let cached = daylight, now.timeIntervalSince(cached.0) < 3_600 { values["daylight"] = cached.1 }
        let contexts = ["Home": "contextHome", "Work / study": "contextWork", "Travelling": "contextTravel", "Resting": "contextRest"]
        if let selected = contexts[settings.context] {
            for signal in contexts.values { values[signal] = signal == selected ? 1 : 0 }
        }
        if now.timeIntervalSince(lastContextRefresh) >= 600 { refreshContext(at: now) }
        let readMusic = settings.music
        worker.async { [weak self] in
            guard let self else { return }
            var signals = values
            if readMusic { signals["music"] = Self.mediaActivity() }
            _ = self.engine.observe(CompassObservation(timestamp: now, seconds: seconds, signals: signals))
            self.persist(force: false)
            self.publish()
        }
    }

    private func persist(force: Bool) {
        guard stateReadable, let url = storageURL, engine.state.hasData,
              force || Date().timeIntervalSince(lastSaved) >= 300 else { return }
        do { try CompassStorage.save(engine.state, to: url); lastSaved = Date(); storageFailed = false }
        catch { storageFailed = true }
    }

    func refreshPresentation(message: String? = nil) {
        let settings = self.settings, permissions = permissionSummary()
        worker.async { [weak self] in self?.publish(message: message, settings: settings, permissions: permissions) }
    }
    private func publish(message: String? = nil, settings explicitSettings: CompassSettings? = nil, permissions: [String: String]? = nil) {
        let state = engine.state, ioError = storageFailed || !stateReadable
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentation.state = state
            self.presentation.settings = explicitSettings ?? self.settings
            self.presentation.permissions = permissions ?? self.permissionSummary()
            if ioError { self.presentation.message = "Local history unavailable. Existing file was not overwritten; estimates remain experimental." }
            else if let message { self.presentation.message = message }
            else {
                self.presentation.message = self.settings.enabled
                    ? "On-device only · sampled about once a minute. Your check-in matters more than an estimate."
                    : "Monitoring off. No new data is being collected."
            }
            self.onChange?(self.presentation)
        }
    }

    private func permissionSummary() -> [String: String] {
        ["activity": settings.activity ? "Counts only; no app names" : "Off",
         "typing": keyboardAllowed ? "Allowed; aggregate counts only" : "Input Monitoring / Accessibility needed",
         "music": "Playback activity only; no song titles",
         "calendar": EKEventStore.authorizationStatus(for: .event) == .fullAccess ? "Allowed; busy time only" : "Calendar permission needed",
         "reminders": EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? "Allowed; daily counts only" : "Reminders permission needed",
         "daylight": locationAuthorized ? "Allowed; no coordinates retained" : "Location permission needed"]
    }
    private func authorizationChanged() { lastContextRefresh = .distantPast; refreshPresentation() }

    private func refreshContext(at now: Date) {
        lastContextRefresh = now
        let generation = contextGeneration
        if settings.calendar, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            contextQueue.async { [weak self] in
                guard let self else { return }
                let end = now.addingTimeInterval(7_200)
                let predicate = self.events.predicateForEvents(withStart: now, end: end, calendars: nil)
                var intervals: [(Date, Date)] = []
                self.events.enumerateEvents(matching: predicate) { event, stop in
                    if intervals.count >= 1_000 { stop.pointee = true; return }
                    if !event.isAllDay, event.status != .canceled, event.availability != .free {
                        intervals.append((max(now, event.startDate), min(end, event.endDate)))
                    }
                }
                var busy = 0.0, lastEnd = now
                for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
                    busy += max(0, interval.1.timeIntervalSince(max(interval.0, lastEnd)))
                    lastEnd = max(lastEnd, interval.1)
                }
                let load = min(1, busy / 7_200)
                DispatchQueue.main.async {
                    guard self.settings.enabled, self.settings.calendar, self.contextGeneration == generation else { return }
                    self.calendarLoad = intervals.count < 1_000 ? (now, load) : nil
                }
            }
        }
        if settings.reminders, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let start = Calendar.current.startOfDay(for: now)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            let completed = events.predicateForCompletedReminders(withCompletionDateStarting: start, ending: now, calendars: nil)
            events.fetchReminders(matching: completed) { [weak self] reminders in
                guard let reminders, reminders.count < 1_000 else { return }
                let count = reminders.count
                DispatchQueue.main.async {
                    guard let self, self.settings.enabled, self.settings.reminders, self.contextGeneration == generation else { return }
                    let due = self.events.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
                    self.events.fetchReminders(matching: due) { [weak self] remaining in
                        guard let remaining, remaining.count < 1_000 else { return }
                        let pending = remaining.count
                        DispatchQueue.main.async {
                            guard let self, self.settings.enabled, self.settings.reminders, self.contextGeneration == generation else { return }
                            self.taskCompletion = (now, Double(count) / Double(max(1, count + pending)))
                        }
                    }
                }
            }
        }
        requestDaylight()
    }

    private var locationAuthorized: Bool {
        guard let status = location?.authorizationStatus else { return false }
        return status == .authorized || status == .authorizedAlways
    }
    private func requestDaylight() {
        guard settings.enabled, settings.daylight else { return }
        if let cached = daylight, Date().timeIntervalSince(cached.0) < 1_800 { return }
        if location == nil { location = CLLocationManager(); location?.desiredAccuracy = kCLLocationAccuracyThreeKilometers; location?.delegate = self }
        if locationAuthorized { location?.requestLocation() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { requestDaylight(); refreshPresentation() }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { daylight = nil; refreshPresentation() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard settings.enabled, settings.daylight, let fix = locations.last, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= 50_000, abs(fix.timestamp.timeIntervalSinceNow) < 900 else { return }
        let now = Date()
        daylight = (now, Self.isDaylight(at: now, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude) ? 1 : 0)
        // fix is not retained, reverse-geocoded, saved or transmitted.
    }
    static func isDaylight(at date: Date, latitude: Double, longitude: Double) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
        let declination = 23.44 * .pi / 180 * sin(2 * .pi * (day - 81) / 365.25)
        let angle = (hour + longitude / 15 - 12) * .pi / 12
        let lat = latitude * .pi / 180
        return sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(angle) > 0
    }

    private static func mediaActivity() -> Double? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(1, &property, 0, nil, &size) == noErr, size <= 65_536 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(1, &property, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var running: UInt32 = 0, bytes: UInt32 = 4
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            address.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &pid) == noErr,
                  let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() else { continue }
            if ["com.apple.music", "com.spotify.client", "com.tidal.desktop"].contains(identifier) { return 1 }
        }
        return 0
    }
}

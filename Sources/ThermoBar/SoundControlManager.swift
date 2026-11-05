import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

struct SoundOutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isDefault: Bool
    let volume: Float?
    var isMuted = false

    var silenceWarning: String? {
        if isMuted { return "Output muted" }
        if let volume, volume <= 0 { return "Device volume is 0%" }
        return nil
    }
}

// Devices may expose mute on the master control or on individual channels.
// Always read back: a successful volume write does not clear hardware mute.
enum SoundOutputMuteControl {
    static func unmute(
        read: (AudioObjectPropertyElement) -> UInt32?,
        write: (AudioObjectPropertyElement, UInt32) -> Bool
    ) -> Bool {
        for element: AudioObjectPropertyElement in [0, 1, 2] {
            guard let muted = read(element), muted != 0 else { continue }
            guard write(element, 0), read(element) == 0 else { return false }
        }
        return true
    }
}

enum SoundOutputDeviceVisibility {
    static func shouldShow(
        isAlive: Bool,
        isHidden: Bool,
        transportType: UInt32?,
        isRunning: Bool
    ) -> Bool {
        guard isAlive, !isHidden else { return false }
        return transportType != kAudioDeviceTransportTypeVirtual || isRunning
    }
}

enum SoundMediaKind: String, Codable, Equatable {
    case music = "Music"
    case video = "Video"
    case game = "Game"
    case audio = "Audio"
}

enum SoundRouteState: Equatable {
    case system
    case starting
    case routed
    case failed(String)
}

enum SoundPlaybackState: Equatable {
    case playing
    case paused
    case starting
    case pausing

    var isTransitioning: Bool { self == .starting || self == .pausing }
    var presentsAsPlaying: Bool { self == .playing || self == .starting }
}

struct SoundPlaybackApp: Equatable {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let displayPID: pid_t
    let name: String
    let bundleIdentifier: String?
    let kind: SoundMediaKind
    let volume: Float
    let selectedOutputUID: String?
    let routeState: SoundRouteState
    var isActive = true
    var isPermanent = false
    var playbackState: SoundPlaybackState = .playing

    var stableIdentifier: String {
        bundleIdentifier ?? "pid:\(pid)"
    }
}

struct SoundPermanentMedia: Codable, Equatable {
    let bundleIdentifier: String
    let name: String
    let kind: SoundMediaKind
}

struct SoundControlSnapshot: Equatable {
    var apps: [SoundPlaybackApp] = []
    var devices: [SoundOutputDevice] = []
    var permanentMedia: [SoundPermanentMedia] = []
    var permanentCandidates: [SoundPermanentMedia] = []
    var message = "Looking for active audio…"
}

struct AudioScene: Codable {
    struct App: Codable {
        let bundleIdentifier: String
        let volume: Float
        let outputUID: String?
    }
    let name: String
    let apps: [App]
    let permanent: [SoundPermanentMedia]
    let deviceUID: String?
    let deviceVolume: Float?
}

final class SoundControlManager {
    var onSnapshotChange: ((SoundControlSnapshot) -> Void)?
    private var sceneGeneration = UUID()

    var savedScenes: [AudioScene] {
        guard let data = defaults.data(forKey: "ThermoBar.AudioScenes.v1") else { return [] }
        return (try? JSONDecoder().decode([AudioScene].self, from: data)) ?? []
    }

    func saveScene(named name: String) {
        let device = latestSnapshot.devices.first(where: \.isDefault)
        let scene = AudioScene(name: name, apps: latestSnapshot.apps.compactMap { app in
            guard let bundle = app.bundleIdentifier else { return nil }
            return AudioScene.App(bundleIdentifier: bundle, volume: app.volume, outputUID: app.selectedOutputUID)
        }, permanent: permanentMedia, deviceUID: device?.uid, deviceVolume: device?.volume)
        let scenes = savedScenes.filter { $0.name != name } + [scene]
        if let data = try? JSONEncoder().encode(scenes) {
            defaults.set(data, forKey: "ThermoBar.AudioScenes.v1")
            showPlaybackFeedback("Saved \(name) scene")
        }
    }

    func applyScene(named name: String) {
        guard let scene = savedScenes.first(where: { $0.name == name }) else { return }
        let available = Set(latestSnapshot.devices.map(\.uid))
        // Resolve every saved output first; disconnected headphones must never silently route to speakers.
        let missing = scene.apps.contains { $0.outputUID.map { !available.contains($0) } ?? false }
            || (scene.deviceUID.map { !available.contains($0) } ?? false)
        guard !missing else { showPlaybackFeedback("\(name): reconnect the saved output first"); return }
        let generation = UUID()
        sceneGeneration = generation
        if let uid = scene.deviceUID, let device = latestSnapshot.devices.first(where: { $0.uid == uid }) {
            showPlaybackFeedback("\(name): switching output…")
            scanQueue.async { [weak self] in
                let success = CoreAudioInventory.setDefaultOutput(device.id)
                let volumeSuccess = scene.deviceVolume.map {
                    success && CoreAudioInventory.setOutputVolume($0, for: device.id)
                } ?? success
                DispatchQueue.main.async {
                    guard let self, self.sceneGeneration == generation else { return }
                    guard success else { self.showPlaybackFeedback("\(name): system output failed"); return }
                    self.latestSnapshot.devices = self.latestSnapshot.devices.map {
                        SoundOutputDevice(id: $0.id, uid: $0.uid, name: $0.name, isDefault: $0.uid == uid,
                            volume: $0.uid == uid && volumeSuccess ? scene.deviceVolume ?? $0.volume : $0.volume,
                            isMuted: $0.isMuted)
                    }
                    self.applySceneApps(scene)
                    if !volumeSuccess { self.showPlaybackFeedback("\(name): applied; device volume unavailable") }
                    self.refresh()
                }
            }
        } else {
            applySceneApps(scene)
        }
    }

    private func applySceneApps(_ scene: AudioScene) {
        permanentMedia = scene.permanent
        persistMediaState()
        publishPermanentChanges()
        var applied = 0
        for saved in scene.apps {
            guard let app = latestSnapshot.apps.first(where: { $0.bundleIdentifier == saved.bundleIdentifier && $0.isActive }) else { continue }
            var preference = preferences[app.pid] ?? Preference()
            preference.volume = min(1, max(0, saved.volume))
            preference.outputUID = saved.outputUID
            preferences[app.pid] = preference
            applyRoute(for: app.pid, rebuild: true)
            applied += 1
        }
        showPlaybackFeedback("\(scene.name): applying to \(applied) active apps · check route status")
        publishUsingCurrentInventory()
    }

    private struct Preference {
        var volume: Float = 1
        var outputUID: String?
        var routeState: SoundRouteState = .system
    }

    private struct PersistedMediaState: Codable {
        var permanent: [SoundPermanentMedia] = []
        var known: [SoundPermanentMedia] = []
    }

    private struct PlaybackOverride {
        let desiredPlaying: Bool
        var isConfirmed: Bool
        var expiresAt: Date
        let token: UUID
    }

    private static let mediaStateKey = "ThermoBar.SoundPermanentMedia.v1"

    private let scanQueue = DispatchQueue(label: "ThermoBar.audio-scan", qos: .utility)
    private let routeQueue = DispatchQueue(label: "ThermoBar.audio-route", qos: .userInitiated)
    private let playbackQueue = DispatchQueue(label: "ThermoBar.playback-control", qos: .userInitiated)
    private let defaults: UserDefaults
    private var isScanning = false
    private var isScanningMusic = false
    private var preferences: [pid_t: Preference] = [:]
    private var routes: [pid_t: IsolatedAudioRoute] = [:]
    private var routeGenerations: [pid_t: UUID] = [:]
    private var latestSnapshot = SoundControlSnapshot()
    private var permanentMedia: [SoundPermanentMedia]
    private var knownMedia: [SoundPermanentMedia]
    private var activationOrder: [String: Int] = [:]
    private var nextActivationOrder = 0
    private var playbackFeedback: String?
    private var recentlyControlledMedia: [String: SoundPermanentMedia] = [:]
    private var playbackOverrides: [String: PlaybackOverride] = [:]
    private var lastMasterTargetIdentifier: String?
    private let playbackCommand: (String) -> PlaybackCommandRunner.Result

    init(
        defaults: UserDefaults = .standard,
        playbackCommand: @escaping (String) -> PlaybackCommandRunner.Result = PlaybackCommandRunner.toggle
    ) {
        self.defaults = defaults
        self.playbackCommand = playbackCommand
        if let data = defaults.data(forKey: Self.mediaStateKey),
           let state = try? JSONDecoder().decode(PersistedMediaState.self, from: data) {
            permanentMedia = state.permanent
            knownMedia = state.known
        } else {
            permanentMedia = []
            knownMedia = []
        }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let scan = CoreAudioInventory.scan()
            DispatchQueue.main.async {
                self.isScanning = false
                self.apply(scan)
            }
        }
    }

    // Pet-only background reads must not rebuild Sound rows, prune app-volume
    // preferences, stop routes or enumerate every output device.
    func refreshMusicActivity(_ completion: @escaping (Bool) -> Void) {
        guard !isScanningMusic else { return }
        isScanningMusic = true
        scanQueue.async { [weak self] in
            let playing = CoreAudioInventory.musicIsPlaying()
            DispatchQueue.main.async {
                self?.isScanningMusic = false
                completion(playing)
            }
        }
    }

    func setVolume(_ volume: Float, for pid: pid_t) {
        guard latestSnapshot.apps.contains(where: { $0.pid == pid }) else { return }
        var preference = preferences[pid] ?? Preference()
        preference.volume = min(1, max(0, volume))
        preferences[pid] = preference
        publishUsingCurrentInventory()
        applyRoute(for: pid)
    }

    func setOutput(uid: String?, for pid: pid_t) {
        guard latestSnapshot.apps.contains(where: { $0.pid == pid }) else { return }
        let device: SoundOutputDevice?
        if let uid {
            device = latestSnapshot.devices.first { $0.uid == uid }
        } else {
            device = latestSnapshot.devices.first(where: \.isDefault)
        }
        guard let device else {
            showPlaybackFeedback("Output unavailable; reconnect it first")
            return
        }
        var preference = preferences[pid] ?? Preference()
        preference.outputUID = uid
        preference.routeState = .starting
        preferences[pid] = preference
        let generation = UUID()
        routeGenerations[pid] = generation
        publishUsingCurrentInventory()
        // Explicit output selection means listen here. Clear mute, but preserve
        // the device's existing volume and the global default output.
        scanQueue.async { [weak self] in
            let audible = CoreAudioInventory.unmuteOutput(device.id)
            DispatchQueue.main.async {
                guard let self, self.routeGenerations[pid] == generation else { return }
                if audible {
                    self.applyRoute(for: pid, rebuild: true)
                } else {
                    self.markRoute(pid: pid, state: .failed("Output is muted; unmute it in Sound Settings"))
                }
                self.refresh()
            }
        }
    }

    func setDeviceVolume(_ volume: Float, for uid: String) {
        guard let device = latestSnapshot.devices.first(where: { $0.uid == uid }) else { return }
        let clampedVolume = min(1, max(0, volume))
        latestSnapshot.devices = latestSnapshot.devices.map { current in
            guard current.uid == uid else { return current }
            return SoundOutputDevice(
                id: current.id,
                uid: current.uid,
                name: current.name,
                isDefault: current.isDefault,
                volume: clampedVolume,
                isMuted: current.isMuted
            )
        }
        onSnapshotChange?(latestSnapshot)
        scanQueue.async { [weak self] in
            let success = CoreAudioInventory.setOutputVolume(clampedVolume, for: device.id)
            DispatchQueue.main.async {
                if !success { self?.showPlaybackFeedback("Device volume could not be changed") }
                self?.refresh()
            }
        }
    }

    func toggleMasterPlayback() {
        let app = latestSnapshot.apps.first(where: { $0.playbackState == .playing })
            ?? lastMasterTargetIdentifier.flatMap { identifier in
                latestSnapshot.apps.first(where: { $0.stableIdentifier == identifier })
            }
            ?? latestSnapshot.apps.first(where: { $0.bundleIdentifier != nil })
        guard let app else {
            showPlaybackFeedback("No media available to control")
            return
        }
        togglePlayback(for: app.stableIdentifier)
    }

    func togglePlayback(for stableIdentifier: String) {
        guard let app = latestSnapshot.apps.first(where: { $0.stableIdentifier == stableIdentifier }),
              let bundleIdentifier = app.bundleIdentifier,
              !app.playbackState.isTransitioning
        else {
            showPlaybackFeedback("Playback control unavailable")
            return
        }

        let media = SoundPermanentMedia(bundleIdentifier: bundleIdentifier, name: app.name, kind: app.kind)
        let desiredPlaying = !app.playbackState.presentsAsPlaying
        let token = UUID()
        playbackOverrides[stableIdentifier] = PlaybackOverride(
            desiredPlaying: desiredPlaying,
            isConfirmed: false,
            expiresAt: Date().addingTimeInterval(10),
            token: token
        )
        lastMasterTargetIdentifier = stableIdentifier
        playbackFeedback = desiredPlaying ? "Starting \(app.name)…" : "Pausing \(app.name)…"
        applyPlaybackPresentation()
        playbackQueue.async { [weak self] in
            guard let self else { return }
            let result = self.playbackCommand(bundleIdentifier)
            DispatchQueue.main.async {
                guard self.playbackOverrides[stableIdentifier]?.token == token else { return }
                switch result {
                case .success:
                    self.recentlyControlledMedia[bundleIdentifier] = media
                    self.playbackOverrides[stableIdentifier]?.isConfirmed = true
                    self.playbackOverrides[stableIdentifier]?.expiresAt = Date().addingTimeInterval(3)
                    self.playbackFeedback = desiredPlaying ? "Playing \(app.name)" : "Paused \(app.name)"
                    self.applyPlaybackPresentation()
                    self.schedulePlaybackRefreshes()
                case .unsupported:
                    self.playbackOverrides.removeValue(forKey: stableIdentifier)
                    self.restorePlaybackPresentation(for: stableIdentifier)
                    self.showPlaybackFeedback("\(app.name) does not expose Play/Pause control")
                case .notInstalled:
                    self.playbackOverrides.removeValue(forKey: stableIdentifier)
                    self.restorePlaybackPresentation(for: stableIdentifier)
                    self.showPlaybackFeedback("\(app.name) is not installed")
                case .timedOut:
                    self.playbackOverrides.removeValue(forKey: stableIdentifier)
                    self.restorePlaybackPresentation(for: stableIdentifier)
                    self.showPlaybackFeedback("\(app.name): playback confirmation timed out · try again")
                }
            }
        }
    }

    func setPermanent(_ media: SoundPermanentMedia, enabled: Bool) {
        permanentMedia.removeAll { $0.bundleIdentifier == media.bundleIdentifier }
        if enabled { permanentMedia.append(media) }
        remember(media)
        persistMediaState()
        publishPermanentChanges()
    }

    func movePermanent(bundleIdentifier: String, direction: Int) {
        guard let index = permanentMedia.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let destination = min(permanentMedia.count - 1, max(0, index + direction))
        guard destination != index else { return }
        permanentMedia.swapAt(index, destination)
        persistMediaState()
        publishPermanentChanges()
    }

    func stopAll() {
        routeQueue.sync {
            for route in routes.values { route.stop() }
            routes.removeAll()
        }
    }

    private func apply(_ inventory: CoreAudioInventory.Result) {
        discardExpiredPlaybackOverrides()
        let activePIDs = Set(inventory.apps.map(\.pid))
        let activeIdentifiers = Set(inventory.apps.map { $0.bundleIdentifier ?? "pid:\($0.pid)" })
        activationOrder = activationOrder.filter { activeIdentifiers.contains($0.key) }
        var didChangeKnownMedia = false
        for app in inventory.apps {
            let identifier = app.bundleIdentifier ?? "pid:\(app.pid)"
            if activationOrder[identifier] == nil {
                nextActivationOrder += 1
                activationOrder[identifier] = nextActivationOrder
            }
            if let bundleIdentifier = app.bundleIdentifier {
                didChangeKnownMedia = remember(
                    SoundPermanentMedia(bundleIdentifier: bundleIdentifier, name: app.name, kind: app.kind)
                ) || didChangeKnownMedia
            }
        }
        if didChangeKnownMedia { persistMediaState() }
        preferences = preferences.filter { activePIDs.contains($0.key) }
        routeGenerations = routeGenerations.filter { activePIDs.contains($0.key) }

        routeQueue.async { [weak self] in
            guard let self else { return }
            let stalePIDs = Set(self.routes.keys).subtracting(activePIDs)
            for pid in stalePIDs {
                self.routes.removeValue(forKey: pid)?.stop()
            }
        }

        latestSnapshot.devices = inventory.devices
        let permanentIDs = Set(permanentMedia.map(\.bundleIdentifier))
        let activeApps = inventory.apps.map { app in
            let preference = preferences[app.pid] ?? Preference()
            var result = SoundPlaybackApp(
                processObjectID: app.processObjectID,
                pid: app.pid,
                displayPID: app.displayPID,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                kind: app.kind,
                volume: preference.volume,
                selectedOutputUID: preference.outputUID,
                routeState: preference.routeState,
                isActive: true,
                isPermanent: app.bundleIdentifier.map(permanentIDs.contains) ?? false
            )
            result.playbackState = playbackState(for: result.stableIdentifier, actuallyActive: true)
            return result
        }.sorted { lhs, rhs in
            let lhsOrder = activationOrder[lhs.stableIdentifier] ?? 0
            let rhsOrder = activationOrder[rhs.stableIdentifier] ?? 0
            if lhsOrder != rhsOrder { return lhsOrder > rhsOrder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let activeBundleIDs = Set(activeApps.compactMap(\.bundleIdentifier))
        recentlyControlledMedia = recentlyControlledMedia.filter { identifier, _ in
            !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
        }
        let inactivePermanent = permanentMedia.compactMap { media -> SoundPlaybackApp? in
            guard !activeBundleIDs.contains(media.bundleIdentifier) else { return nil }
            var result = SoundPlaybackApp(
                processObjectID: 0,
                pid: 0,
                displayPID: 0,
                name: media.name,
                bundleIdentifier: media.bundleIdentifier,
                kind: media.kind,
                volume: 1,
                selectedOutputUID: nil,
                routeState: .system,
                isActive: false,
                isPermanent: true
            )
            result.playbackState = playbackState(for: result.stableIdentifier, actuallyActive: false)
            return result
        }
        let retainedIDs = activeBundleIDs.union(permanentIDs)
        let inactiveRecentlyControlled = recentlyControlledMedia.values
            .filter { !retainedIDs.contains($0.bundleIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { media in
                var result = SoundPlaybackApp(
                    processObjectID: 0,
                    pid: 0,
                    displayPID: 0,
                    name: media.name,
                    bundleIdentifier: media.bundleIdentifier,
                    kind: media.kind,
                    volume: 1,
                    selectedOutputUID: nil,
                    routeState: .system,
                    isActive: false,
                    isPermanent: false
                )
                result.playbackState = playbackState(for: result.stableIdentifier, actuallyActive: false)
                return result
            }
        latestSnapshot.apps = activeApps + inactivePermanent + inactiveRecentlyControlled
        latestSnapshot.permanentMedia = permanentMedia
        latestSnapshot.permanentCandidates = knownMedia
        latestSnapshot.message = playbackFeedback ?? inventory.message
        onSnapshotChange?(latestSnapshot)
    }

    private func publishUsingCurrentInventory() {
        latestSnapshot.apps = latestSnapshot.apps.map { app in
            guard let preference = preferences[app.pid] else { return app }
            return SoundPlaybackApp(
                processObjectID: app.processObjectID,
                pid: app.pid,
                displayPID: app.displayPID,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                kind: app.kind,
                volume: preference.volume,
                selectedOutputUID: preference.outputUID,
                routeState: preference.routeState,
                isActive: app.isActive,
                isPermanent: app.isPermanent,
                playbackState: app.playbackState
            )
        }
        onSnapshotChange?(latestSnapshot)
    }

    private func publishPermanentChanges() {
        let permanentIDs = Set(permanentMedia.map(\.bundleIdentifier))
        let active = latestSnapshot.apps.filter(\.isActive).map { app in
            var updated = app
            updated.isPermanent = app.bundleIdentifier.map(permanentIDs.contains) ?? false
            return updated
        }
        let activeBundleIDs = Set(active.compactMap(\.bundleIdentifier))
        let inactive = permanentMedia.compactMap { media -> SoundPlaybackApp? in
            guard !activeBundleIDs.contains(media.bundleIdentifier) else { return nil }
            var result = SoundPlaybackApp(
                processObjectID: 0,
                pid: 0,
                displayPID: 0,
                name: media.name,
                bundleIdentifier: media.bundleIdentifier,
                kind: media.kind,
                volume: 1,
                selectedOutputUID: nil,
                routeState: .system,
                isActive: false,
                isPermanent: true
            )
            result.playbackState = playbackState(for: result.stableIdentifier, actuallyActive: false)
            return result
        }
        let inactiveRecent = latestSnapshot.apps.filter { app in
            guard !app.isActive, !app.isPermanent else { return false }
            return app.bundleIdentifier.map { !permanentIDs.contains($0) } ?? true
        }
        latestSnapshot.apps = active + inactive + inactiveRecent
        latestSnapshot.permanentMedia = permanentMedia
        latestSnapshot.permanentCandidates = knownMedia
        onSnapshotChange?(latestSnapshot)
    }

    @discardableResult
    private func remember(_ media: SoundPermanentMedia) -> Bool {
        if let index = knownMedia.firstIndex(where: { $0.bundleIdentifier == media.bundleIdentifier }) {
            guard knownMedia[index] != media else { return false }
            knownMedia[index] = media
        } else {
            knownMedia.append(media)
            knownMedia.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return true
    }

    private func persistMediaState() {
        let state = PersistedMediaState(permanent: permanentMedia, known: knownMedia)
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.mediaStateKey)
    }

    private func playbackState(for identifier: String, actuallyActive: Bool) -> SoundPlaybackState {
        guard let override = playbackOverrides[identifier] else {
            return actuallyActive ? .playing : .paused
        }
        if override.expiresAt <= Date() {
            playbackOverrides.removeValue(forKey: identifier)
            return actuallyActive ? .playing : .paused
        }
        if override.isConfirmed, override.desiredPlaying == actuallyActive {
            playbackOverrides.removeValue(forKey: identifier)
            return actuallyActive ? .playing : .paused
        }
        if override.isConfirmed {
            return override.desiredPlaying ? .playing : .paused
        }
        return override.desiredPlaying ? .starting : .pausing
    }

    private func applyPlaybackPresentation() {
        for index in latestSnapshot.apps.indices {
            let identifier = latestSnapshot.apps[index].stableIdentifier
            let actuallyActive = latestSnapshot.apps[index].isActive
            latestSnapshot.apps[index].playbackState = playbackState(
                for: identifier,
                actuallyActive: actuallyActive
            )
        }
        if let playbackFeedback { latestSnapshot.message = playbackFeedback }
        onSnapshotChange?(latestSnapshot)
    }

    private func restorePlaybackPresentation(for identifier: String) {
        guard let index = latestSnapshot.apps.firstIndex(where: { $0.stableIdentifier == identifier }) else { return }
        latestSnapshot.apps[index].playbackState = latestSnapshot.apps[index].isActive ? .playing : .paused
    }

    private func discardExpiredPlaybackOverrides() {
        let now = Date()
        playbackOverrides = playbackOverrides.filter { $0.value.expiresAt > now }
    }

    private func schedulePlaybackRefreshes() {
        for delay in [0.15, 0.55, 1.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.playbackFeedback = nil
            self.refresh()
        }
    }

    private func showPlaybackFeedback(_ message: String) {
        playbackFeedback = message
        latestSnapshot.message = message
        onSnapshotChange?(latestSnapshot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.playbackFeedback == message else { return }
            self.playbackFeedback = nil
            self.refresh()
        }
    }

    private func applyRoute(for pid: pid_t, rebuild: Bool = false) {
        guard let app = latestSnapshot.apps.first(where: { $0.pid == pid }),
              var preference = preferences[pid]
        else { return }

        let needsRoute = preference.volume < 0.999 || preference.outputUID != nil
        if !needsRoute {
            routeGenerations.removeValue(forKey: pid)
            preference.routeState = .system
            preferences[pid] = preference
            publishUsingCurrentInventory()
            routeQueue.async { [weak self] in
                self?.routes.removeValue(forKey: pid)?.stop()
            }
            return
        }

        if !rebuild {
            switch preference.routeState {
            case .starting, .routed:
                let desiredVolume = preference.volume
                routeQueue.async { [weak self] in
                    self?.routes[pid]?.volume = desiredVolume
                }
                return
            case .system, .failed:
                break
            }
        }

        preference.routeState = .starting
        preferences[pid] = preference
        publishUsingCurrentInventory()

        let targetDevice: SoundOutputDevice?
        if let uid = preference.outputUID {
            targetDevice = latestSnapshot.devices.first { $0.uid == uid }
        } else {
            targetDevice = latestSnapshot.devices.first(where: \.isDefault)
        }
        guard let targetDevice else {
            markRoute(pid: pid, state: .failed("No output device"))
            return
        }

        let desiredVolume = preference.volume
        let desiredUID = preference.outputUID
        let generation = UUID()
        routeGenerations[pid] = generation
        routeQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.routes.removeValue(forKey: pid)?.stop(waitForExit: true)
                let route = try IsolatedAudioRoute(
                    processID: app.pid,
                    outputUID: targetDevice.uid,
                    volume: desiredVolume,
                    onEvent: { [weak self] event in
                        DispatchQueue.main.async {
                            guard let self,
                                  self.routeGenerations[pid] == generation,
                                  self.preferences[pid]?.outputUID == desiredUID
                            else { return }
                            switch event {
                            case .ready:
                                // Slider events can arrive while the helper is starting.
                                // Confirm the latest gain, not its launch-time value.
                                let volume = self.preferences[pid]?.volume ?? desiredVolume
                                self.routeQueue.async { [weak self] in self?.routes[pid]?.volume = volume }
                                self.markRoute(pid: pid, state: .routed)
                            case let .failed(message):
                                self.markRoute(pid: pid, state: .failed(message))
                            }
                        }
                    }
                )
                self.routes[pid] = route
            } catch {
                self.routes.removeValue(forKey: pid)?.stop()
                DispatchQueue.main.async {
                    guard self.routeGenerations[pid] == generation else { return }
                    self.markRoute(pid: pid, state: .failed(Self.concise(error)))
                }
            }
        }
    }

    private func markRoute(pid: pid_t, state: SoundRouteState) {
        guard var preference = preferences[pid] else { return }
        preference.routeState = state
        preferences[pid] = preference
        publishUsingCurrentInventory()
    }

    private static func concise(_ error: Error) -> String {
        if let error = error as? IsolatedAudioRoute.RouteError { return error.userMessage }
        return "Routing unavailable"
    }
}

enum PlaybackCommandRunner {
    enum Result: Equatable {
        case success
        case unsupported
        case notInstalled
        case timedOut
    }

    static func toggle(bundleIdentifier: String) -> Result {
        guard bundleIdentifier.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else { return .unsupported }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            return .notInstalled
        }
        let escapedIdentifier = bundleIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(escapedIdentifier)\" to playpause"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return execute(process)
    }

    // Called on the playback worker, never the main/UI queue. Do not allow a
    // stuck automation request to hold all subsequent playback controls forever.
    static func execute(_ process: Process, timeout: TimeInterval = 8) -> Result {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            guard exited.wait(timeout: .now() + timeout) == .success else {
                if process.isRunning { process.terminate() }
                return .timedOut
            }
            return process.terminationStatus == 0 ? .success : .unsupported
        } catch {
            return .unsupported
        }
    }
}

final class IsolatedAudioRoute {
    enum Event: Equatable {
        case ready
        case failed(String)
    }

    enum RouteError: Error {
        case helperUnavailable
        case launchFailed
        case rejected(String)

        var userMessage: String {
            switch self {
            case .helperUnavailable: "Audio helper unavailable"
            case .launchFailed: "Audio helper did not start"
            case let .rejected(message): message
            }
        }
    }

    var volume: Float {
        didSet { send("volume \(min(1, max(0, volume)))") }
    }

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let onEvent: (Event) -> Void
    private let stateLock = NSLock()
    private var responseBuffer = Data()
    private var expectedStop = false
    private var didFinishStartup = false
    private let exitSignal = DispatchSemaphore(value: 0)

    init(
        processID: pid_t,
        outputUID: String,
        volume: Float,
        onEvent: @escaping (Event) -> Void,
        helperURL overrideHelperURL: URL? = nil,
        // A cold Bluetooth output can take several seconds to open. Keep the
        // deadline bounded, off the UI thread, without killing a healthy start.
        startupTimeout: TimeInterval = 8
    ) throws {
        self.volume = min(1, max(0, volume))

        let helperURL = overrideHelperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/local.thermobar.audiohelper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw RouteError.helperUnavailable
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helperURL
        process.arguments = [
            // AudioObjectIDs belong to a Core Audio client. Resolve stable
            // process/device identities inside the isolated helper instead.
            "--pid", String(processID),
            "--output-uid", outputUID,
            "--volume", String(self.volume),
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.input = input
        self.output = output
        self.onEvent = onEvent

        let exitSignal = self.exitSignal
        process.terminationHandler = { [weak self] process in
            exitSignal.signal()
            self?.processDidExit(process)
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw RouteError.launchFailed
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
            self?.failStartup("Audio connection timed out")
        }
    }

    deinit { stop() }

    func stop(waitForExit: Bool = false) {
        stateLock.lock()
        guard !expectedStop else {
            stateLock.unlock()
            return
        }
        expectedStop = true
        didFinishStartup = true
        stateLock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        send("stop")
        try? input.fileHandleForWriting.close()
        // The helper fades down and destroys its tap on a normal stop. SIGTERM
        // is only a timeout fallback; immediate termination cut off mid-wave.
        if waitForExit, process.isRunning {
            _ = exitSignal.wait(timeout: .now() + 0.3)
        }
        let process = self.process
        if process.isRunning {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (waitForExit ? 0 : 0.3)) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func send(_ command: String) {
        guard process.isRunning, let data = "\(command)\n".data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        stateLock.lock()
        guard !expectedStop, !didFinishStartup else {
            stateLock.unlock()
            return
        }
        guard data.count <= 4_096, responseBuffer.count <= 4_096 - data.count else {
            didFinishStartup = true
            stateLock.unlock()
            fail("Invalid audio helper response")
            return
        }
        responseBuffer.append(data)
        guard let newline = responseBuffer.firstIndex(of: 0x0A) else {
            stateLock.unlock()
            return
        }
        let lineData = responseBuffer[..<newline]
        let line = String(data: lineData, encoding: .utf8) ?? ""
        didFinishStartup = true
        stateLock.unlock()

        output.fileHandleForReading.readabilityHandler = nil
        if line == "READY" {
            onEvent(.ready)
            return
        }
        let message = line
            .split(separator: "|", maxSplits: 1)
            .last
            .map(String.init) ?? "Audio route unavailable"
        fail(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func failStartup(_ message: String) {
        stateLock.lock()
        guard !expectedStop, !didFinishStartup else {
            stateLock.unlock()
            return
        }
        didFinishStartup = true
        stateLock.unlock()
        fail(message)
    }

    private func fail(_ message: String) {
        stateLock.lock()
        guard !expectedStop else {
            stateLock.unlock()
            return
        }
        expectedStop = true
        stateLock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        onEvent(.failed(message.isEmpty ? "Audio route unavailable" : message))
    }

    private func processDidExit(_ process: Process) {
        stateLock.lock()
        let wasExpected = expectedStop
        if !wasExpected {
            expectedStop = true
            didFinishStartup = true
        }
        stateLock.unlock()
        guard !wasExpected else { return }
        output.fileHandleForReading.readabilityHandler = nil
        onEvent(.failed(process.terminationStatus == 0 ? "Audio route ended" : "Audio route failed safely"))
    }
}

private enum CoreAudioInventory {
    static func musicIsPlaying() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList).contains { object in
            guard let running: UInt32 = scalar(object, selector: kAudioProcessPropertyIsRunningOutput), running != 0,
                  let pid: pid_t = scalar(object, selector: kAudioProcessPropertyPID), pid > 0, pid != ownPID,
                  let owner = AudioProcessOwnership.ownerPID(startingAt: pid, parentPID: parentPID,
                    isApplication: { NSRunningApplication(processIdentifier: $0) != nil }), owner != ownPID,
                  let app = NSRunningApplication(processIdentifier: owner), !app.isTerminated else { return false }
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            return classify(name: name, bundleURL: app.bundleURL) == .music
        }
    }

    struct App {
        let processObjectID: AudioObjectID
        let pid: pid_t
        let displayPID: pid_t
        let name: String
        let bundleIdentifier: String?
        let kind: SoundMediaKind
    }

    struct Result {
        let apps: [App]
        let devices: [SoundOutputDevice]
        let message: String
    }

    static func scan() -> Result {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = objectIDs(system, selector: kAudioHardwarePropertyDevices)
        let defaultDevice: AudioObjectID? = scalar(system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        let devices = deviceIDs.compactMap { device -> SoundOutputDevice? in
            guard !objectIDs(device, selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput).isEmpty,
                  let uid = string(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(device, selector: kAudioObjectPropertyName)
            else { return nil }

            let isAlive: UInt32? = scalar(device, selector: kAudioDevicePropertyDeviceIsAlive)
            let isHidden: UInt32? = scalar(device, selector: kAudioDevicePropertyIsHidden)
            let transportType: UInt32? = scalar(device, selector: kAudioDevicePropertyTransportType)
            let isRunning: UInt32? = scalar(device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
            guard SoundOutputDeviceVisibility.shouldShow(
                isAlive: (isAlive ?? 1) != 0,
                isHidden: (isHidden ?? 0) != 0,
                transportType: transportType,
                isRunning: (isRunning ?? 0) != 0
            ) else { return nil }

            return SoundOutputDevice(
                id: device,
                uid: uid,
                name: name,
                isDefault: device == defaultDevice,
                volume: outputVolume(device),
                isMuted: [0, 1, 2].contains { outputMute(device, element: $0) == 1 }
            )
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = objectIDs(system, selector: kAudioHardwarePropertyProcessObjectList).compactMap { objectID -> App? in
            guard let isRunning: UInt32 = scalar(objectID, selector: kAudioProcessPropertyIsRunningOutput),
                  isRunning != 0,
                  let pid: pid_t = scalar(objectID, selector: kAudioProcessPropertyPID),
                  pid > 0,
                  pid != ownPID
            else { return nil }

            guard let displayPID = AudioProcessOwnership.ownerPID(
                startingAt: pid,
                parentPID: parentPID,
                isApplication: { NSRunningApplication(processIdentifier: $0) != nil }
            ),
            displayPID != ownPID,
            let running = NSRunningApplication(processIdentifier: displayPID),
            !running.isTerminated
            else { return nil }
            let bundleID = running.bundleIdentifier ?? string(objectID, selector: kAudioProcessPropertyBundleID)
            let name = running.localizedName ?? bundleID ?? "Process \(pid)"
            return App(
                processObjectID: objectID,
                pid: pid,
                displayPID: displayPID,
                name: name,
                bundleIdentifier: bundleID,
                kind: classify(name: name, bundleURL: running.bundleURL)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let message: String
        if deviceIDs.isEmpty {
            message = "Audio inventory unavailable"
        } else if apps.isEmpty {
            message = "No app is currently playing audio"
        } else {
            message = "\(apps.count) active audio \(apps.count == 1 ? "app" : "apps")"
        }
        return Result(apps: apps, devices: devices, message: message)
    }

    private static func classify(name: String, bundleURL: URL?) -> SoundMediaKind {
        let lower = name.lowercased()
        if ["music", "spotify", "tidal", "deezer", "vox", "audirvana"].contains(where: lower.contains) {
            return .music
        }
        if ["tv", "quicktime", "vlc", "iina", "netflix", "youtube"].contains(where: lower.contains) {
            return .video
        }
        if let bundleURL,
           let category = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           category == "public.app-category.games" {
            return .game
        }
        return .audio
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private static func scalar<T: FixedWidthInteger>(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var property = address(selector, scope: scope)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func objectIDs(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func outputVolume(_ device: AudioObjectID) -> Float? {
        if let master = floatProperty(device, selector: kAudioDevicePropertyVolumeScalar, element: 0) {
            return master
        }
        let channels = [1, 2].compactMap {
            floatProperty(device, selector: kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement($0))
        }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    @discardableResult
    static func setOutputVolume(_ volume: Float, for device: AudioObjectID) -> Bool {
        let changed: Bool
        if setFloatProperty(volume, on: device, selector: kAudioDevicePropertyVolumeScalar, element: 0) {
            changed = true
        } else {
            let left = setFloatProperty(volume, on: device, selector: kAudioDevicePropertyVolumeScalar, element: 1)
            let right = setFloatProperty(volume, on: device, selector: kAudioDevicePropertyVolumeScalar, element: 2)
            changed = left || right
        }
        return changed && (volume <= 0 || unmuteOutput(device))
    }

    private static func outputMute(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> UInt32? {
        var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &property),
              AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    static func unmuteOutput(_ device: AudioObjectID) -> Bool {
        SoundOutputMuteControl.unmute(read: { outputMute(device, element: $0) }, write: { element, value in
            var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue else { return false }
            var value = value
            return AudioObjectSetPropertyData(device, &property, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        })
    }

    static func setDefaultOutput(_ device: AudioObjectID) -> Bool {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    private static func floatProperty(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var property = address(selector, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(object, &property) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setFloatProperty(
        _ value: Float,
        on object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var property = address(selector, scope: kAudioDevicePropertyScopeOutput, element: element)
        var isSettable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &property),
              AudioObjectIsPropertySettable(object, &property, &isSettable) == noErr,
              isSettable.boolValue
        else { return false }
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(object, &property, 0, nil, size, &mutableValue) == noErr
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard result == Int32(expectedSize) else { return nil }
        return pid_t(info.pbi_ppid)
    }
}

enum AudioProcessOwnership {
    static func ownerPID(
        startingAt pid: pid_t,
        parentPID: (pid_t) -> pid_t?,
        isApplication: (pid_t) -> Bool
    ) -> pid_t? {
        var current = pid
        var visited = Set<pid_t>()
        for _ in 0..<8 {
            guard current > 1, visited.insert(current).inserted else { return nil }
            if isApplication(current) { return current }
            guard let parent = parentPID(current), parent != current else { return nil }
            current = parent
        }
        return nil
    }
}


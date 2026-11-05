import AppKit

private final class DesktopPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopPetController {
    var onChange: ((PetSettings, PetActivity) -> Void)?
    var onMonitoringChange: (() -> Void)?
    private(set) var settings: PetSettings
    private(set) var activity = PetActivity()
    private let defaults: UserDefaults
    private let reader: PetCodexActivityReader
    private let queue = DispatchQueue(label: "MyBar.pet-codex-metadata", qos: .utility)
    private var timer: Timer?
    private var panel: DesktopPetPanel?
    private var canvas: PetCanvasView?
    private var generation = UUID()
    private var reading = false
    private var suspensionReasons = Set<String>()
    private var suspended: Bool { !suspensionReasons.isEmpty }
    private var observers: [NSObjectProtocol] = []
    private var positionSave: DispatchWorkItem?
    var needsMusicMonitoring: Bool { settings.enabled && settings.music && !suspended }

    init(defaults: UserDefaults = .standard, reader: PetCodexActivityReader = PetCodexActivityReader()) {
        self.defaults = defaults; self.reader = reader
        settings = defaults.data(forKey: PetSettings.key).flatMap { try? JSONDecoder().decode(PetSettings.self, from: $0) } ?? PetSettings()
        settings.sanitize()
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason, pause) in [
            (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display", true), (NSWorkspace.screensDidWakeNotification, "display", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSuspended(pause, reason: reason) })
        }
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.publish() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.placePanel(recenter: false) })
        reconcile()
    }

    func stop() {
        generation = UUID(); timer?.invalidate(); timer = nil
        positionSave?.cancel(); positionSave = nil
        canvas?.update(activity, active: false, reduceMotion: true)
        panel?.orderOut(nil)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
    deinit { stop() }

    func configure(_ next: PetSettings) {
        let previous = settings
        let position = (settings.x, settings.y)
        settings = next; settings.x = position.0; settings.y = position.1
        settings.sanitize(); save()
        if settings.enabled == previous.enabled && settings.codex == previous.codex &&
            settings.music == previous.music && settings.fans == previous.fans {
            // Live size drags must not restart background checks or restore an
            // old window origin. Resize in place, retaining the user's anchor.
            if settings.scale != previous.scale {
                panel?.setContentSize(NSSize(width: 320 * settings.scale, height: 240 * settings.scale))
            }
            publish()
        } else { reconcile() }
    }

    func updateFans(_ rpm: [Double?]) {
        let next = PetActivity.fansAreSpinning(rpm)
        guard activity.fansSpinning != next else { return }
        activity.fansSpinning = next; publish()
    }
    func updateMusic(_ snapshot: SoundControlSnapshot) {
        let next = snapshot.apps.contains { $0.kind == .music && $0.isActive && $0.playbackState == .playing }
        updateMusicPlaying(next)
    }
    func updateMusicPlaying(_ next: Bool) {
        guard activity.musicPlaying != next else { return }
        activity.musicPlaying = next; publish()
    }
    func recenter() { placePanel(recenter: true); rememberPosition() }

    private func setSuspended(_ value: Bool, reason: String) {
        let wasSuspended = suspended
        if value { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        if wasSuspended != suspended { reconcile() }
    }

    private func reconcile() {
        generation = UUID(); timer?.invalidate(); timer = nil
        let visible = settings.enabled && !suspended && PetSpriteAtlas.shared.isAvailable
        if visible {
            if panel == nil {
                let panel = DesktopPetPanel(contentRect: NSRect(origin: .zero, size: PetCanvasView.canvasSize),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "MyBar · Capri Pet"
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                panel.isMovable = true; panel.isMovableByWindowBackground = true
                panel.setFrameAutosaveName("MyBar.DesktopPet")
                panel.level = .floating; panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                panel.animationBehavior = .none
                let canvas = PetCanvasView(frame: NSRect(origin: .zero, size: PetCanvasView.canvasSize))
                canvas.draggable = true
                panel.contentView = canvas; self.panel = panel; self.canvas = canvas
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                    object: panel, queue: .main) { [weak self] _ in self?.schedulePositionSave() })
            }
            placePanel(recenter: false)
            panel?.orderFrontRegardless()
            if settings.codex {
                pollCodex()
                let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollCodex() }
                timer.tolerance = 0.6; RunLoop.main.add(timer, forMode: .common); self.timer = timer
            }
        } else { panel?.orderOut(nil) }
        if !settings.enabled || !settings.codex {
            activity.codexWorking = false; activity.codexAvailable = false
            queue.async { [reader] in reader.clear() }
        }
        publish(); onMonitoringChange?()
    }

    private func pollCodex() {
        guard settings.enabled, settings.codex, !suspended, !reading else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty else {
            activity.codexWorking = false; activity.codexAvailable = true; publish(); return
        }
        reading = true
        let generation = self.generation
        queue.async { [weak self, reader] in
            let result = reader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard self.generation == generation else { return }
                self.activity.codexWorking = result.working; self.activity.codexAvailable = result.available
                self.publish()
            }
        }
    }

    var displayedActivity: PetActivity {
        PetActivity(codexWorking: settings.codex && activity.codexWorking,
            codexAvailable: activity.codexAvailable, musicPlaying: settings.music && activity.musicPlaying,
            fansSpinning: settings.fans && activity.fansSpinning)
    }
    private func publish() {
        canvas?.update(displayedActivity, active: settings.enabled && !suspended,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        onChange?(settings, displayedActivity)
    }

    static func clampedOrigin(_ origin: NSPoint, size: NSSize, screens: [NSRect]) -> NSPoint {
        guard let screen = screens.first(where: { $0.intersects(NSRect(origin: origin, size: size)) }) ?? screens.first else { return origin }
        return NSPoint(x: min(max(screen.minX, origin.x), max(screen.minX, screen.maxX - size.width)),
                       y: min(max(screen.minY, origin.y), max(screen.minY, screen.maxY - size.height)))
    }
    private func placePanel(recenter: Bool) {
        guard let panel else { return }
        let size = NSSize(width: 320 * settings.scale, height: 240 * settings.scale)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: screen.maxX - size.width - 30, y: screen.minY + 32)
        if !recenter {
            if panel.setFrameUsingName("MyBar.DesktopPet") { origin = panel.frame.origin }
            else if let x = settings.x, let y = settings.y { origin = NSPoint(x: x, y: y) }
        }
        panel.setFrame(NSRect(origin: Self.clampedOrigin(origin, size: size, screens: NSScreen.screens.map(\.visibleFrame)), size: size), display: true)
    }
    private func rememberPosition() {
        guard let panel else { return }
        // Do not reposition a window during a native drag. Clamp only when
        // restoring/recentering, so a fast pointer can never lose the pet.
        settings.x = panel.frame.origin.x; settings.y = panel.frame.origin.y; save()
        panel.saveFrame(usingName: "MyBar.DesktopPet")
    }
    private func schedulePositionSave() {
        positionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rememberPosition() }
        positionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: PetSettings.key) }
    }
}

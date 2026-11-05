import AppKit
import Darwin
import TrackpadGestureCore

final class TrackpadHelperClient {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let reader = DispatchQueue(label: "MyBar.trackpad-pipe", qos: .userInitiated)
    private var buffer = GestureLineBuffer()
    private var stopped = false // Main thread only.
    private var ready = false
    var onReply: ((TrackpadReply) -> Void)?
    var onFailure: (() -> Void)?
    var isRunning: Bool { process.isRunning }

    init(url: URL, arguments: [String] = []) { process.executableURL = url; process.arguments = arguments }
    func start() throws {
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.fail() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // A single POSIX read returns available bytes immediately. Foundation's
            // length-based pipe read can wait for more bytes and delay the ready/swipe message.
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else { handle.readabilityHandler = nil; self?.fail(); return }
            let data = Data(bytes.prefix(count))
            self?.reader.async { [weak self] in self?.consume(data) }
        }
        try process.run()
        let fd = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.stopped, !self.ready else { return }
            self.fail()
        }
    }
    func send(_ command: TrackpadCommand) {
        guard !stopped, process.isRunning, var data = try? JSONEncoder().encode(command), data.count < 1_024 else { return }
        data.append(10)
        let fd = input.fileHandleForWriting.fileDescriptor
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != data.count { fail() }
    }
    private func consume(_ data: Data) {
        do {
            for line in try buffer.consume(data) {
                let reply = try JSONDecoder().decode(TrackpadReply.self, from: line)
                guard reply.version == 1 else { fail(); return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    if reply.kind == .ready { self.ready = true }
                    self.onReply?(reply)
                }
            }
        } catch { fail() }
    }
    private func fail() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            let callback = self.onFailure
            self.stop(); callback?()
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close() // EOF tells the helper to unregister and stop devices.
        try? output.fileHandleForReading.close()
        let child = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if child.isRunning { child.terminate() } // Only our isolated child; never the app/audio/fan helpers.
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // A wedged private framework must not keep monitoring after Disable.
            // This PID is our owned child, retained by Process until it is reaped.
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        }
    }
}

final class TrackpadGestureManager {
    static let settingsKey = "MyBar.TrackpadGestures.v1"
    private let defaults: UserDefaults
    private let helperURL: URL
    private var helper: TrackpadHelperClient?
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var started = false
    private var sessionActive = true
    private var failed = false
    private var generation = UUID().uuidString
    private var target: GestureForeground?
    private var gate = GestureDispatchGate()
    private(set) var settings: TrackpadGestureSettings
    private(set) var status = "Off · no trackpad monitoring"
    private(set) var needsPermission = false
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, helperURL: URL? = nil) {
        self.defaults = defaults
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/local.mybar.trackpadhelper")
        settings = defaults.data(forKey: Self.settingsKey).flatMap {
            try? JSONDecoder().decode(TrackpadGestureSettings.self, from: $0)
        } ?? TrackpadGestureSettings()
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.target?.pid else { return }
            self.refresh()
        })
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = false; self?.refresh()
            })
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = true; self?.refresh()
            })
        }
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.sessionActive = false; self?.refresh()
        })
        lockObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.sessionActive = true; self?.refresh()
        })
        refresh()
    }
    func stop() {
        started = false
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver); observers.removeAll()
        lockObservers.forEach(DistributedNotificationCenter.default().removeObserver); lockObservers.removeAll()
        helper?.stop(); helper = nil; target = nil; generation = UUID().uuidString
    }
    deinit { stop() }
    func setSettings(_ settings: TrackpadGestureSettings) {
        self.settings = settings
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        failed = false; refresh()
    }
    func retry() { failed = false; helper?.stop(); helper = nil; refresh() }

    func refresh() {
        guard started else { return }
        generation = UUID().uuidString // Invalidate pending gestures on every activation/settings/lifecycle change.
        target = nil; needsPermission = false
        guard settings.enabled else { suspend("Off · no trackpad monitoring"); return }
        guard sessionActive, Self.sessionIsUnlocked else { suspend("Paused · Mac asleep or session locked"); return }
        guard BrowserTabDispatcher.permissionGranted else {
            needsPermission = true; suspend("Accessibility permission needed for browser shortcuts"); return
        }
        let conflict = TrackpadSystemConflict.read()
        guard conflict == .clear else {
            suspend(conflict == .reserved ? "Paused · macOS already uses four-finger horizontal swipes" : "Paused · verify four-finger system gestures, then Recheck")
            return
        }
        guard !failed else { suspend("Gesture helper unavailable · Recheck to retry"); return }
        target = GestureForeground.current()
        if helper == nil {
            let client = TrackpadHelperClient(url: helperURL)
            helper = client
            client.onReply = { [weak self, weak client] reply in
                guard let self, let client, self.helper === client else { return }
                self.receive(reply)
            }
            client.onFailure = { [weak self, weak client] in
                guard let self, let client, self.helper === client else { return }
                self.failed = true; self.helper = nil; self.target = nil
                self.status = "Gesture helper stopped · MyBar continues normally · Recheck to retry"
                self.onChange?()
            }
            do { try client.start() } catch {
                client.stop(); helper = nil; failed = true
                status = "Gesture helper missing or could not start · Recheck to retry"; onChange?(); return
            }
        }
        status = target == nil ? "Enabled · waiting for Edge, Chrome, Safari, Firefox or Brave" : "Checking trackpad availability…"
        helper?.send(TrackpadCommand(generation: generation, active: target != nil, settings: settings))
        onChange?()
    }

    private func suspend(_ message: String) {
        helper?.stop(); helper = nil; status = message; onChange?()
    }
    private static var sessionIsUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }
    private func receive(_ reply: TrackpadReply) {
        switch reply.kind {
        case .ready: break
        case .failure:
            failed = true; suspend("Private multitouch API unavailable · MyBar continues normally")
        case .devices:
            guard reply.generation == generation, let count = reply.deviceCount, (0...8).contains(count) else { return }
            if count == 0 { status = "No multitouch device found · connect a trackpad, then Recheck" }
            else if let target { status = "Listening in \(target.browser.title) · \(count) device(s) · lift fingers once to arm" }
            else { status = "Ready · waiting for a supported foreground browser" }
            onChange?()
        case .swipe:
            guard gate.accept(reply, generation: generation, enabled: settings.enabled && sessionActive,
                              now: ProcessInfo.processInfo.systemUptime),
                  let target, let direction = reply.direction else { return }
            // Recheck permission and system conflict only per completed gesture, never per touch frame.
            guard Self.sessionIsUnlocked, BrowserTabDispatcher.permissionGranted, TrackpadSystemConflict.read() == .clear else { refresh(); return }
            BrowserTabDispatcher.send(direction, to: target)
        }
    }
}

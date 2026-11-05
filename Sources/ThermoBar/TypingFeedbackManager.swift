import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import Darwin
import TypingFeedbackProtocol

struct TypingFeedbackState {
    var settings = TypingFeedbackSettings()
    var status = "Off · Bluetooth headphones only"
    var ready = false
    var listening = false
    var permissionNeeded = false
    var canConfirmHeadphones = false
}

/// Main-thread lifecycle and a passive key-down listener. Audio lives in another process.
final class TypingFeedbackManager {
    var onChange: ((TypingFeedbackState) -> Void)?
    var onPermissionPrompt: (() -> Void)?
    private static let preference = "TheBar.TypingFeedback.v1"
    private let defaults: UserDefaults
    private let helperURLOverride: URL?
    private let outputProvider: () -> TypingOutput?
    private let permissionCheck: () -> Bool
    private(set) var settings: TypingFeedbackSettings
    private var output: TypingOutput?
    private var generation = UUID()
    private let inventoryQueue = DispatchQueue(label: "TheBar.typing-output", qos: .utility)
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var observers: [NSObjectProtocol] = []
    private var awake = true
    private var process: Process?
    private var socketFD: Int32 = -1
    private var responsePipe: Pipe?
    private var responseBuffer = Data()
    private var timeout: DispatchWorkItem?
    private var ready = false
    private var pendingPreview = false
    private var previewRelease: DispatchWorkItem?
    private var tap: TypingKeyListener?
    private var lastPulse = -Double.infinity
    private var state = TypingFeedbackState()

    init(defaults: UserDefaults = .standard, helperURL: URL? = nil,
         outputProvider: @escaping () -> TypingOutput? = TypingOutputInventory.defaultOutput,
         permissionCheck: @escaping () -> Bool = { CGPreflightListenEventAccess() || AXIsProcessTrusted() }) {
        self.defaults = defaults
        helperURLOverride = helperURL; self.outputProvider = outputProvider; self.permissionCheck = permissionCheck
        settings = defaults.data(forKey: Self.preference).flatMap { try? PropertyListDecoder().decode(TypingFeedbackSettings.self, from: $0) } ?? TypingFeedbackSettings()
        settings.sanitize()
    }
    deinit { stop() }
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.awake = false; self?.reconcile() })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.awake = true; self?.reconcile() })
        }
        reconcile()
    }
    func stop() {
        pendingPreview = false
        generation = UUID(); stopTap(); stopHelper(); removeHardwareListener()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
    func setEnabled(_ enabled: Bool) {
        pendingPreview = false
        settings.enabled = enabled; save()
        if enabled, !permissionAllowed { requestPermission(); return }
        reconcile()
    }
    func selectSound(_ name: String) {
        guard MechanicalKeySound.names.contains(name) else { return }
        pendingPreview = false
        settings.sound = name; save(); reconcile()
    }
    func setVolume(_ value: Float) {
        settings.volume = value; settings.sanitize(); save()
        send(Data([0x56, UInt8((settings.volume * 100).rounded())]))
        state.settings = settings; onChange?(state)
    }
    func confirmHeadphones() {
        guard let output, output.isBluetooth, !output.isKnownSpeaker else { return }
        settings.confirmedHeadphoneUIDs.append(output.uid); settings.sanitize(); save(); reconcile()
    }
    func preview() {
        guard settings.volume > 0 else { publish("Raise the typing volume before previewing"); return }
        if ready { pulse(isPreview: true); if tap == nil { schedulePreviewRelease() }; return }
        pendingPreview = true
        reconcile()
    }
    func requestPermission(openSettings: Bool = false) {
        onPermissionPrompt?()
        _ = CGRequestListenEventAccess()
        if openSettings, !permissionAllowed,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        reconcile()
    }
    func refresh() { reconcile() }
    /// Called when the menu reopens after Settings. Never prompts or restarts an
    /// already healthy stream, and never retries an audio/helper failure in a loop.
    func resumeIfAuthorized() {
        guard settings.enabled, state.permissionNeeded, permissionAllowed else { return }
        reconcile()
    }
    private var permissionAllowed: Bool { permissionCheck() }
    private func save() { if let data = try? PropertyListEncoder().encode(settings) { defaults.set(data, forKey: Self.preference) } }
    private func publish(_ status: String, confirm: Bool = false, permission: Bool = false) {
        state = TypingFeedbackState(settings: settings, status: status, ready: ready,
                                   listening: tap != nil, permissionNeeded: permission, canConfirmHeadphones: confirm)
        onChange?(state)
    }
    private func reconcile() {
        generation = UUID(); let generation = self.generation
        stopTap(); stopHelper()
        guard settings.enabled || pendingPreview else { removeHardwareListener(); publish("Off · Bluetooth headphones only"); return }
        installHardwareListener()
        guard awake else { pendingPreview = false; publish("Paused while the Mac is asleep or inactive"); return }
        publish("Checking Bluetooth headphones…")
        inventoryQueue.async { [weak self] in
            let output = self?.outputProvider()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.output = output
                guard let output, output.isBluetooth else { self.pendingPreview = false; self.publish("Select Bluetooth headphones as system output first"); return }
                guard output.isAllowed(confirmed: self.settings.confirmedHeadphoneUIDs) else {
                    self.pendingPreview = false
                    self.publish(output.isKnownSpeaker ? "Paused · Bluetooth speakers are not allowed" : "\(output.name): confirm that this device is headphones", confirm: !output.isKnownSpeaker)
                    return
                }
                guard self.permissionAllowed || self.pendingPreview else {
                    self.publish("Input Monitoring required · Allow typing… then reopen MyBar", permission: true); return
                }
                self.launch(output, generation: generation)
            }
        }
    }
    private func installHardwareListener() {
        guard hardwareListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reconcile() }
        hardwareListener = listener
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
    private func removeHardwareListener() {
        guard let listener = hardwareListener else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        hardwareListener = nil
    }
    private func launch(_ output: TypingOutput, generation: UUID) {
        let url = helperURLOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/local.thermobar.typinghelper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { pendingPreview = false; publish("Typing helper unavailable; other MyBar features are unaffected"); return }
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else { pendingPreview = false; publish("Typing audio connection unavailable"); return }
        var noSignal: Int32 = 1
        setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        let childInput = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: false)
        let child = Process(), response = Pipe()
        child.executableURL = url
        child.arguments = ["--uid", output.uid, "--sound", settings.sound, "--volume", String(settings.volume), "--parent", String(getpid())]
        if settings.confirmedHeadphoneUIDs.contains(output.uid) { child.arguments?.append("--confirmed-headphones") }
        child.standardInput = childInput; child.standardOutput = response; child.standardError = FileHandle.nullDevice
        process = child; socketFD = descriptors[0]; responsePipe = response
        response.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, data.count < 4_096 else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.process === child else { return }
                self.responseBuffer.append(data)
                guard self.responseBuffer.count < 4_096 else { self.stopTap(); self.stopHelper(); self.publish("Invalid typing helper response"); return }
                guard self.responseBuffer.contains(0x0A) else { return }
                let message = String(data: self.responseBuffer, encoding: .utf8) ?? ""
                self.responseBuffer.removeAll(keepingCapacity: true)
                if message.hasPrefix("READY"), !self.ready {
                    self.timeout?.cancel(); self.ready = true
                    let shouldListen = self.settings.enabled && self.permissionAllowed
                    let listening = shouldListen && self.startTap()
                    if self.pendingPreview {
                        self.pendingPreview = false
                        self.pulse(isPreview: true)
                        self.publish(listening ? "Ready · \(output.name) · preview sent"
                                     : self.settings.enabled ? "Preview sent · automatic typing is not active" : "Preview sent · automatic typing is off",
                                     permission: self.settings.enabled && !self.permissionAllowed)
                        if !listening { self.schedulePreviewRelease() }
                    } else if listening { self.publish("Ready · \(output.name) · secure fields stay silent") }
                    else { self.stopHelper(); self.publish("Key listener unavailable · check Input Monitoring and Retry", permission: !self.permissionAllowed) }
                } else if message.contains("ERROR") || message.contains("STOPPED") {
                    let detail = message.split(separator: "|", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Typing audio unavailable"
                    self.pendingPreview = false; self.stopTap(); self.stopHelper(); self.publish(detail)
                }
            }
        }
        child.terminationHandler = { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let self, self.generation == generation, self.process === child else { return }
            self.pendingPreview = false; self.stopTap(); self.stopHelper(); self.publish("Typing audio stopped · press Retry")
        } }
        do { try child.run(); close(descriptors[1]) }
        catch { close(descriptors[1]); pendingPreview = false; stopHelper(); publish("Could not start typing audio; MyBar keeps running"); return }
        publish("Preparing \(settings.sound) for \(output.name)…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, !self.ready else { return }
            self.pendingPreview = false; self.stopTap(); self.stopHelper(); self.publish("Typing audio timed out · press Retry")
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    private func send(_ data: Data) {
        guard socketFD >= 0 else { return }
        _ = data.withUnsafeBytes { Darwin.send(socketFD, $0.baseAddress, $0.count, MSG_DONTWAIT) }
    }
    private func pulse(isPreview: Bool = false) {
        guard ready, awake, isPreview || !IsSecureEventInputEnabled() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPulse >= 0.008 else { return }
        lastPulse = now; TypingFeedbackPacket.sendPulse(to: socketFD, at: now, isPreview: isPreview)
    }
    func endPreview() {
        guard tap == nil, pendingPreview || previewRelease != nil,
              !(settings.enabled && permissionAllowed) else { return }
        pendingPreview = false
        generation = UUID() // Cancel an in-flight, preview-only preparation too.
        finishPreview()
    }
    private func finishPreview() {
        stopHelper()
        if !settings.enabled { removeHardwareListener() }
        let needsPermission = settings.enabled && !permissionAllowed
        publish(settings.enabled ? (needsPermission ? "Allow Input Monitoring for automatic typing feedback" : "Preview finished · press Retry to start typing feedback") : "Off · preview finished", permission: needsPermission)
    }
    private func schedulePreviewRelease() {
        previewRelease?.cancel()
        let generation = self.generation
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.tap == nil else { return }
            self.finishPreview()
        }
        previewRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: release)
    }
    private func startTap() -> Bool {
        guard permissionAllowed else { return false }
        let listenerGeneration = generation
        tap = TypingKeyListener(descriptor: socketFD) { [weak self] in
            guard let self, self.generation == listenerGeneration else { return }
            self.stopTap(); self.stopHelper(); self.publish("Key listener paused · press Retry")
        }
        return tap != nil
    }
    private func stopTap() {
        tap?.stop(); tap = nil
    }
    private func stopHelper() {
        previewRelease?.cancel(); previewRelease = nil
        ready = false; timeout?.cancel(); timeout = nil
        send(Data([0x51]))
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        responsePipe?.fileHandleForReading.readabilityHandler = nil
        responsePipe = nil
        responseBuffer.removeAll(keepingCapacity: false)
        let old = process; process = nil
        old?.terminationHandler = nil
        if let old, old.isRunning { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { if old.isRunning { old.terminate() } } }
    }
}

import Foundation
import CoreGraphics
import IOKit
import Darwin
import CTrackpadBridge
import TrackpadGestureCore

// No elevation, event tap, keyboard capture, UI, sockets or disk history in this helper.
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--validate-protocol") {
    let command = TrackpadCommand(generation: UUID().uuidString, active: false, settings: TrackpadGestureSettings())
    guard let data = try? JSONEncoder().encode(command), let decoded = try? JSONDecoder().decode(TrackpadCommand.self, from: data),
          decoded.version == 1, !decoded.active else { exit(2) }
    print("VALID|Trackpad helper protocol|no monitoring or event injection")
    exit(0)
}
if CommandLine.arguments.contains("--probe") {
    let available = mybar_trackpad_bridge_available() != 0
    print(available ? "VALID|Private multitouch symbols resolved; monitoring not started" : "UNAVAILABLE|Private multitouch symbols missing")
    exit(available ? 0 : 2)
}

final class TouchRuntime {
    let queue = DispatchQueue(label: "MyBar.trackpad-control", qos: .userInitiated)
    private let lock = NSLock()
    private var command: TrackpadCommand?
    private var detectors: [UInt: FourFingerSwipeRecognizer] = [:]
    private var lastEmit = -Double.infinity
    private var input = GestureLineBuffer()
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pendingRescan: DispatchWorkItem?
    private var terminationSource: DispatchSourceSignal?
    private let ipcTest = CommandLine.arguments.contains("--ipc-test")

    func run() {
        guard ipcTest || mybar_trackpad_bridge_available() != 0 else { emit(TrackpadReply(.failure)); exit(2) }
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        terminationSource?.setEventHandler { [weak self] in self?.finish() }
        terminationSource?.resume()
        if !ipcTest { observeDevices() }
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            if count <= 0 { handle.readabilityHandler = nil; self?.queue.async { self?.finish() }; return }
            let data = Data(bytes.prefix(count))
            self?.queue.async { self?.consume(data) }
        }
        emit(TrackpadReply(.ready))
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { finish() }
        do {
            for line in try input.consume(data) {
                let next = try JSONDecoder().decode(TrackpadCommand.self, from: line)
                guard next.version == 1, UUID(uuidString: next.generation) != nil else { finish() }
                apply(next)
            }
        } catch { finish() }
    }

    private func apply(_ next: TrackpadCommand) {
        // Stop may join framework callbacks, so never call it while holding the detector lock.
        mybar_trackpad_stop()
        lock.lock(); detectors.removeAll(keepingCapacity: true); command = next; lock.unlock()
        if ipcTest, next.active { emit(TrackpadReply(.failure)); finish() }
        let count = ipcTest ? 0 : next.active ? mybar_trackpad_start(contactFrame) : mybar_trackpad_device_count()
        guard count >= 0 else { emit(TrackpadReply(.failure)); finish() }
        emit(TrackpadReply(.devices, generation: next.generation, deviceCount: Int(count)))
    }

    func frame(device: UInt, contacts: UnsafePointer<MyBarContact>?, count: Int, time: Double) {
        lock.lock()
        guard let command, command.active else { lock.unlock(); return }
        guard detectors[device] != nil || detectors.count < 8 else { lock.unlock(); return }
        var detector = detectors[device] ?? FourFingerSwipeRecognizer()
        guard count >= 0, count <= 4, count == 0 || contacts != nil else {
            detector.cancel(); detectors[device] = detector; lock.unlock(); return
        }
        let points: [TrackpadContact] = (0..<count).map {
            let contact = contacts![$0]
            return TrackpadContact(id: Int(contact.identifier), x: Double(contact.x), y: Double(contact.y))
        }
        let result = detector.update(points, at: time, sensitivity: command.sensitivity, reversed: command.reversed)
        detectors[device] = detector
        let now = ProcessInfo.processInfo.systemUptime
        // Cross-device cooldown too: touching two trackpads must not double-switch.
        let fire = result != nil && now - lastEmit >= FourFingerSwipeRecognizer.cooldown
            && !CGEventSource.buttonState(.combinedSessionState, button: .left)
            && !CGEventSource.buttonState(.combinedSessionState, button: .right)
        if fire { lastEmit = now }
        lock.unlock()
        guard fire, let direction = result else { return }
        queue.async { [weak self] in
            self?.emit(TrackpadReply(.swipe, generation: command.generation, direction: direction, uptime: now))
        }
    }

    private func observeDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        // Notification-driven discovery covers built-in, USB and Bluetooth hotplug. No polling.
        for service in ["AppleMultitouchDevice", "IOHIDDevice"] {
            for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port, kind, IOServiceMatching(service), deviceChanged,
                    Unmanaged.passUnretained(self).toOpaque(), &iterator)
                if result == KERN_SUCCESS {
                    iterators.append(iterator)
                    drain(iterator) // Arm notification without treating initial inventory as a change.
                }
            }
        }
    }

    func rescan(_ iterator: io_iterator_t) {
        drain(iterator)
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.command; self.lock.unlock()
            if let current { self.apply(current) }
        }
        pendingRescan = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func emit(_ event: TrackpadReply) {
        guard var data = try? JSONEncoder().encode(event), data.count < 1_024 else { finish() }
        data.append(10)
        let count = data.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if count != data.count { finish() } // No buffered backlog, blocking or retry loop.
    }

    private func finish() -> Never {
        FileHandle.standardInput.readabilityHandler = nil
        pendingRescan?.cancel()
        mybar_trackpad_stop()
        for iterator in iterators { IOObjectRelease(iterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        exit(0)
    }
}

private func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
}
private let deviceChanged: IOServiceMatchingCallback = { context, iterator in
    guard let context else { return }
    Unmanaged<TouchRuntime>.fromOpaque(context).takeUnretainedValue().rescan(iterator)
}
private let contactFrame: MyBarTrackpadCallback = { device, contacts, count, time in
    runtime.frame(device: device, contacts: contacts, count: Int(count), time: time)
}
private let runtime = TouchRuntime()
runtime.run()
dispatchMain()

import ApplicationServices
import Carbon
import Darwin
import Foundation
import TypingFeedbackProtocol

/// The key-to-socket path never waits behind UI redraws, app polling or menu tracking.
/// A duplicated descriptor stays valid until this worker exits, including during teardown.
final class TypingKeyListener {
    private let descriptor: Int32
    private let onDisabled: () -> Void
    private let lifecycle = NSLock()
    private var stopped = false
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastPulse = -Double.infinity // Worker-thread only.
    private var reportedDisabled = false

    init?(descriptor: Int32, onDisabled: @escaping () -> Void) {
        let copy = dup(descriptor)
        guard copy >= 0 else { return nil }
        self.descriptor = copy; self.onDisabled = onDisabled
        _ = fcntl(copy, F_SETFD, FD_CLOEXEC)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<TypingKeyListener>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if !owner.reportedDisabled {
                    owner.reportedDisabled = true
                    DispatchQueue.main.async(execute: owner.onDisabled)
                }
            } else if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                      !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl),
                      !IsSecureEventInputEnabled() {
                let now = ProcessInfo.processInfo.systemUptime
                if now - owner.lastPulse >= 0.008 {
                    owner.lastPulse = now
                    TypingFeedbackPacket.sendPulse(to: owner.descriptor, at: now)
                }
                // No characters, key codes, event strings or app targets are inspected.
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue, callback: callback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            close(copy); return nil
        }
        self.tap = tap; self.source = source
        let worker = Thread { [self] in
            let current = CFRunLoopGetCurrent()!
            lifecycle.lock()
            let shouldRun = !stopped
            loop = current
            if shouldRun { CFRunLoopAddSource(current, source, .commonModes) }
            lifecycle.unlock()
            if shouldRun { CFRunLoopRun() }
            CFRunLoopRemoveSource(current, source, .commonModes)
            CFMachPortInvalidate(tap)
            close(copy)
            lifecycle.lock(); loop = nil; lifecycle.unlock()
        }
        worker.name = "TheBar Typing Feedback"
        worker.qualityOfService = .userInteractive
        worker.start()
    }
    func stop() {
        lifecycle.lock()
        stopped = true
        let current = loop
        lifecycle.unlock()
        if let tap { CFMachPortInvalidate(tap) }
        if let current {
            // A queued block also handles Stop arriving just before CFRunLoopRun.
            CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(current) }
            CFRunLoopWakeUp(current)
        }
    }
}

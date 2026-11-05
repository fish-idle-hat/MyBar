import AppKit
import Darwin
import MenuBarControlProtocol

private func emit(_ response: MenuBarHelperResponse) {
    guard let data = try? JSONEncoder().encode(response) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let engine = MenuBarAgentAssertion()
if CommandLine.arguments.contains("--probe") {
    emit(MenuBarHelperResponse(id: "probe", state: engine.available ? .ready : .error,
                              message: engine.available ? "MenuBarAgent runtime API is available; no restriction activated." : "MenuBarAgent runtime API unavailable."))
    exit(engine.available ? 0 : 2)
}

guard let parentIndex = CommandLine.arguments.firstIndex(of: "--parent-pid"),
      CommandLine.arguments.indices.contains(parentIndex + 1),
      let parentPID = Int32(CommandLine.arguments[parentIndex + 1]), parentPID == getppid(), parentPID > 1 else { exit(2) }

signal(SIGPIPE, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var lastHeartbeat = ProcessInfo.processInfo.systemUptime
let leaseLock = NSLock()
var input = Data()
var applying = false
var applied = false
var stopping = false
var observers: [NSObjectProtocol] = []

func finish(_ message: String, id: String = "") {
    guard !stopping else { return }
    stopping = true
    engine.release()
    emit(MenuBarHelperResponse(id: id, state: .revealed, message: message))
    FileHandle.standardInput.readabilityHandler = nil
    exit(0)
}

let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { finish("Helper stopped; restriction released.") }
terminate.resume()
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { finish("Helper interrupted; restriction released.") }
interrupt.resume()

// Any app/layout change releases the allow-list, so newly launched apps are not silently hidden.
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
             NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == getpid() || app.processIdentifier == parentPID { return }
        finish("Layout or running apps changed; originals restored.")
    })
}
observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                       object: nil, queue: .main) { _ in finish("Display changed; originals restored.") })

// Keep the lease off the private-API/main queue: a stuck Objective-C call must not
// also disable crash recovery. Process death releases the process-scoped assertion.
let leaseQueue = DispatchQueue(label: "ThermoBar.menu-helper-watchdog", qos: .utility)
let lease = DispatchSource.makeTimerSource(queue: leaseQueue)
var recoveryScheduled = false
lease.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
lease.setEventHandler {
    leaseLock.lock()
    let expired = ProcessInfo.processInfo.systemUptime - lastHeartbeat > 8
    leaseLock.unlock()
    if !recoveryScheduled && (getppid() != parentPID || kill(parentPID, 0) != 0 || expired) {
        recoveryScheduled = true
        DispatchQueue.main.async { finish("Parent disconnected; originals restored.") }
        leaseQueue.asyncAfter(deadline: .now() + 0.5) { _exit(0) }
    }
}
lease.resume()

// This undocumented assertion can interfere with Notification Center on macOS 27.
// Release it before interaction with the clock/system area; do not imitate system UI.
let systemAreaGuard = DispatchSource.makeTimerSource(queue: .main)
systemAreaGuard.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
systemAreaGuard.setEventHandler {
    guard applied else { return }
    let point = NSEvent.mouseLocation
    if NSScreen.screens.contains(where: { screen in
        point.x >= screen.frame.maxX - 150 && point.x <= screen.frame.maxX
            && point.y >= screen.frame.maxY - 40 && point.y <= screen.frame.maxY
    }) {
        finish("System menu area entered; originals restored for normal system controls.")
    }
}
systemAreaGuard.resume()

FileHandle.standardInput.readabilityHandler = { handle in
    let chunk = handle.availableData
    DispatchQueue.main.async {
        if chunk.isEmpty { finish("Parent closed connection; originals restored."); return }
        input.append(chunk)
        guard input.count <= 65_536 else { finish("Invalid oversized request; originals restored."); return }
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline)
            input.removeSubrange(...newline)
            guard let request = try? JSONDecoder().decode(MenuBarHelperRequest.self, from: line) else {
                finish("Invalid request; originals restored."); return
            }
            leaseLock.lock()
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            leaseLock.unlock()
            switch request.action {
            case .heartbeat: break
            case .reveal: finish("Originals restored.", id: request.id)
            case .hide:
                guard !applying, !applied else { finish("Unexpected replacement; originals restored."); return }
                let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                guard let allowed = MenuBarHidingPolicy.allowedBundleIDs(hidden: Set(request.hiddenBundleIDs),
                                                                       running: running, visible: Set(request.visibleBundleIDs)) else {
                    emit(MenuBarHelperResponse(id: request.id, state: .error, message: "Rejected unsafe or stale app selection."))
                    finish("No restriction retained."); return
                }
                guard MenuBarHidingPolicy.experimentalActivationAllowed else {
                    emit(MenuBarHelperResponse(id: request.id, state: .error,
                        message: "Experimental hiding disabled after a failed system-control preservation check."))
                    finish("No restriction activated."); return
                }
                applying = true
                engine.activate(allowed: allowed) { error in
                    guard !stopping else { return }
                    applying = false
                    if let error {
                        emit(MenuBarHelperResponse(id: request.id, state: .error, message: error))
                        finish("Failed safely; originals restored.")
                    } else {
                        applied = true
                        emit(MenuBarHelperResponse(id: request.id, state: .applied, message: "Restriction applied; verify actual visibility."))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if applying { finish("Activation timed out; originals restored.") }
                }
            }
        }
    }
}
emit(MenuBarHelperResponse(id: "", state: engine.available ? .ready : .error,
                          message: engine.available ? "Experimental helper ready." : "MenuBarAgent API unavailable."))
RunLoop.main.run()

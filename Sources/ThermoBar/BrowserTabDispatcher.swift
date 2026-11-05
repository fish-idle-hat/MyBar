import AppKit
import ApplicationServices
import Carbon
import TrackpadGestureCore

enum GestureBrowser: String, CaseIterable {
    case edge = "com.microsoft.edgemac"
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case firefox = "org.mozilla.firefox"
    case brave = "com.brave.Browser"

    var title: String { switch self {
    case .edge: "Edge"; case .chrome: "Chrome"; case .safari: "Safari"
    case .firefox: "Firefox"; case .brave: "Brave"
    } }
    func shortcut(_ direction: TabSwipe) -> (key: CGKeyCode, flags: CGEventFlags) {
        if self == .safari {
            return (48, direction == .next ? .maskControl : [.maskControl, .maskShift])
        }
        // Positional, even if Firefox's Control-Tab is configured for recent-use order.
        return (direction == .next ? 124 : 123, [.maskCommand, .maskAlternate])
    }
}

struct GestureForeground: Equatable {
    let pid: pid_t
    let browser: GestureBrowser
    static func current() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              let id = app.bundleIdentifier, let browser = GestureBrowser(rawValue: id) else { return nil }
        return Self(pid: app.processIdentifier, browser: browser)
    }
}

struct GestureDispatchGate {
    private var lastAccepted = -Double.infinity
    mutating func accept(_ reply: TrackpadReply, generation: String, enabled: Bool, now: Double) -> Bool {
        guard enabled, reply.version == 1, reply.kind == .swipe, reply.generation == generation,
              reply.direction != nil, let issued = reply.uptime, issued.isFinite, now.isFinite,
              (0...0.5).contains(now - issued), issued - lastAccepted >= FourFingerSwipeRecognizer.cooldown else { return false }
        lastAccepted = issued
        return true
    }
}

enum BrowserTabDispatcher {
    static var permissionGranted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    /// No activation, global key injection, modifier down/up, focus changes or AppleScript.
    @discardableResult
    static func send(_ direction: TabSwipe, to target: GestureForeground,
                     frontmost: () -> GestureForeground? = GestureForeground.current,
                     allowed: () -> Bool = { permissionGranted },
                     secureInput: () -> Bool = { IsSecureEventInputEnabled() },
                     modifiers: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
                     post: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) -> Bool {
        guard allowed(), frontmost() == target, !secureInput(),
              modifiers()
                .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty else { return false }
        let shortcut = target.browser.shortcut(direction)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: false) else { return false }
        down.flags = shortcut.flags; up.flags = shortcut.flags
        // A final activation check immediately before targeted posting closes the queued-message race.
        guard frontmost() == target, allowed() else { return false }
        post(down, target.pid); post(up, target.pid)
        return true // Accepted by posting API; it cannot acknowledge the browser's tab change.
    }
}

enum TrackpadSystemConflict: Equatable {
    case clear, reserved, unknown
    static func selection(three: Int?, four: Int?) -> Self {
        // The Three Fingers UI choice can leave BOTH mappings enabled. A physical
        // test on macOS 27 confirmed four-finger desktop switching with (2, 2).
        // Only an explicit four=0 frees this gesture; three never overrides it.
        guard let four else { return .unknown }
        if four == 0 { return .clear }
        if four == 1 || four == 2 { return .reserved }
        return .unknown
    }
    static func classify(_ values: [Self]) -> Self {
        if values.contains(.reserved) { return .reserved }
        // One device's explicit Off must not imply an unknown second device is free.
        let globalKnown = values.count == 3 && values[2] == .clear
        let bothDevicesKnown = values.count >= 2 && values[0] == .clear && values[1] == .clear
        return globalKnown || bothDevicesKnown ? .clear : .unknown
    }
    static func read() -> Self {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        func value(_ key: String, domain: CFString) -> Int? {
            let host = CFPreferencesCopyValue(key as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber
            let general = CFPreferencesCopyValue(key as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
            return (host ?? general)?.intValue
        }
        var values: [Self] = domains.map { domain in
            // No setters: reload only preferences owned by System Settings.
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            return selection(three: value("TrackpadThreeFingerHorizSwipeGesture", domain: domain as CFString),
                             four: value("TrackpadFourFingerHorizSwipeGesture", domain: domain as CFString))
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        values.append(selection(three: value("com.apple.trackpad.threeFingerHorizSwipeGesture", domain: kCFPreferencesAnyApplication),
                                four: value("com.apple.trackpad.fourFingerHorizSwipeGesture", domain: kCFPreferencesAnyApplication)))
        return classify(values)
    }
}

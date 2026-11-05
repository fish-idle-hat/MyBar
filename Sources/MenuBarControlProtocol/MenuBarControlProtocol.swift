import Foundation

public struct MenuBarHelperRequest: Codable {
    public enum Action: String, Codable { case hide, heartbeat, reveal }
    public let id: String
    public let action: Action
    public let hiddenBundleIDs: [String]
    public let visibleBundleIDs: [String]

    public init(id: String, action: Action, hiddenBundleIDs: [String] = [], visibleBundleIDs: [String] = []) {
        self.id = id
        self.action = action
        self.hiddenBundleIDs = hiddenBundleIDs
        self.visibleBundleIDs = visibleBundleIDs
    }
}

public struct MenuBarHelperResponse: Codable {
    public enum State: String, Codable { case ready, applied, revealed, error }
    public let id: String
    public let state: State
    public let message: String

    public init(id: String, state: State, message: String) {
        self.id = id
        self.state = state
        self.message = message
    }
}

public enum MenuBarHidingPolicy {
    // The live macOS 27.0.1 check hid system controls despite the allow-list.
    // Keep activation off until preservation is verified on the actual OS build.
    public static let experimentalActivationAllowed = false
    public static let protectedBundleIDs: Set<String> = [
        "local.thermobar.app", "local.thermobar.menuhelper",
        "com.apple.controlcenter", "com.apple.MenuBarAgent", "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent", "com.apple.Siri", "com.apple.Spotlight",
        "com.apple.wifi.WiFiAgent", "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui", "com.apple.loginwindow",
    ]

    public static func canHide(_ bundleID: String) -> Bool {
        !bundleID.hasPrefix("com.apple.") && !protectedBundleIDs.contains(bundleID)
            && bundleID.count <= 255 && bundleID.contains(".")
            && bundleID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
    }

    // This API is an allow-list. Start with *all* running apps, not just discovered extras.
    // Never accept an empty/invalid hide set, and never subtract protected owners.
    public static func allowedBundleIDs(hidden: Set<String>, running: Set<String>, visible: Set<String>) -> [String]? {
        guard !hidden.isEmpty, hidden.count <= 64, hidden.allSatisfy(canHide), hidden.isSubset(of: running) else { return nil }
        return running.union(visible).union(protectedBundleIDs).subtracting(hidden).sorted()
    }
}

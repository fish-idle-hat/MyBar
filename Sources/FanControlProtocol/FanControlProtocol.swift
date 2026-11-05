import Foundation

public enum FanHelperConstants {
    public static let machServiceName = "local.thermobar.fanhelper"
    public static let plistName = "local.thermobar.fanhelper.plist"
    public static let version = 1
    public static let watchdogSeconds: TimeInterval = 8
}

public struct FanCapability: Codable, Equatable {
    public let index: Int
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let modeKey: String

    public init(index: Int, minimumRPM: Double, maximumRPM: Double, modeKey: String) {
        self.index = index
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.modeKey = modeKey
    }
}

public struct FanTarget: Codable, Equatable {
    public let index: Int
    public let rpm: Double

    public init(index: Int, rpm: Double) {
        self.index = index
        self.rpm = rpm
    }
}

public struct FanTargetRequest: Codable, Equatable {
    public let targets: [FanTarget]

    public init(targets: [FanTarget]) {
        self.targets = targets
    }
}

public struct FanHelperStatus: Codable, Equatable {
    public let version: Int
    public let isReady: Bool
    public let fans: [FanCapability]
    public let activeTargets: [FanTarget]
    public let message: String

    public init(version: Int, isReady: Bool, fans: [FanCapability], activeTargets: [FanTarget], message: String) {
        self.version = version
        self.isReady = isReady
        self.fans = fans
        self.activeTargets = activeTargets
        self.message = message
    }
}

public struct FanCommandResponse: Codable, Equatable {
    public let success: Bool
    public let message: String
    public let appliedTargets: [FanTarget]

    public init(success: Bool, message: String, appliedTargets: [FanTarget] = []) {
        self.success = success
        self.message = message
        self.appliedTargets = appliedTargets
    }
}

@objc public protocol ThermoBarFanHelperProtocol {
    func status(withReply reply: @escaping (Data) -> Void)
    func applyTargets(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func restoreSystem(withReply reply: @escaping (Data) -> Void)
    func heartbeat(withReply reply: @escaping (Bool) -> Void)
}

public enum FanResponseProfile: Int, CaseIterable {
    case quiet
    case balanced
    case cool

    public var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .cool: return "Cool"
        }
    }
}

public enum SmartFanCurve {
    /// Returns a normalized demand. Zero means leave fan control to macOS.
    public static func demand(temperature: Double, profile: FanResponseProfile) -> Double {
        let offset: Double
        switch profile {
        case .quiet: offset = 5
        case .balanced: offset = 0
        case .cool: offset = -5
        }
        let temperature = temperature - offset
        let points: [(Double, Double)] = [(50, 0), (55, 0.35), (70, 0.60), (85, 0.85), (92, 1)]
        guard temperature > points[0].0 else { return 0 }
        guard temperature < points.last!.0 else { return 1 }

        for pair in zip(points, points.dropFirst()) {
            let (low, high) = pair
            if temperature <= high.0 {
                let fraction = (temperature - low.0) / (high.0 - low.0)
                return low.1 + fraction * (high.1 - low.1)
            }
        }
        return 1
    }

    public static func targets(capabilities: [FanCapability], demand: Double) -> [FanTarget] {
        let demand = min(1, max(0, demand))
        return capabilities.map { fan in
            FanTarget(
                index: fan.index,
                rpm: fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * demand
            )
        }
    }
}

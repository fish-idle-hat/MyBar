import Foundation

public enum SwipeSensitivity: String, Codable, CaseIterable {
    case low, medium, high
    public var distance: Double { switch self { case .low: 0.18; case .medium: 0.12; case .high: 0.08 } }
}

public struct TrackpadGestureSettings: Codable, Equatable {
    public var enabled = false
    public var sensitivity: SwipeSensitivity = .medium
    public var reversed = false
    public init() {}
}

public enum TabSwipe: String, Codable { case next, previous }

public struct TrackpadContact {
    public let id: Int
    public let x: Double
    public let y: Double
    public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// Four stable identities, coherent translation, then complete lift. No scroll events.
/// A detector belongs to one physical device and is never shared between callbacks without a lock.
public struct FourFingerSwipeRecognizer {
    public static let cooldown = 0.30
    private enum Phase { case waitingForLift, idle, moving, lifting }
    private var phase: Phase = .waitingForLift
    private var anchors: [TrackpadContact] = []
    private var firstContact: Double?
    private var started = 0.0
    private var liftingAt = 0.0
    private var lastTime: Double?
    private var lastFire = -Double.infinity
    private var dx = 0.0
    private var dy = 0.0
    public var isTracking: Bool { phase == .moving || phase == .lifting }
    public init() {}

    public mutating func cancel() {
        phase = .waitingForLift; anchors.removeAll(keepingCapacity: true)
        firstContact = nil; dx = 0; dy = 0
    }

    public mutating func update(_ contacts: [TrackpadContact], at time: Double,
                                sensitivity: SwipeSensitivity = .medium, reversed: Bool = false) -> TabSwipe? {
        guard time.isFinite, contacts.count <= 4,
              contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(contacts.map(\.id)).count == contacts.count else { cancel(); return nil }
        if let lastTime, time <= lastTime || (isTracking && time - lastTime > 0.25) { cancel() }
        lastTime = time
        if contacts.isEmpty {
            let eligible = (phase == .moving || (phase == .lifting && time - liftingAt <= 0.18))
                && (0.06...1.5).contains(time - started) && abs(dx) >= sensitivity.distance
                && abs(dx) >= abs(dy) * 2 && time - lastFire >= Self.cooldown
            let next = reversed ? dx > 0 : dx < 0
            phase = .idle; anchors.removeAll(keepingCapacity: true); firstContact = nil
            dx = 0; dy = 0
            if eligible { lastFire = time; return next ? .next : .previous }
            return nil
        }
        guard phase != .waitingForLift else { return nil }
        if phase == .idle {
            if firstContact == nil { firstContact = time }
            guard time - (firstContact ?? time) <= 0.20 else { cancel(); return nil }
            if contacts.count == 4 {
                anchors = contacts; started = time; dx = 0; dy = 0; phase = .moving
            }
            return nil
        }
        if phase == .lifting {
            // A new/replaced contact or re-landing must not join a completed stroke.
            if time - liftingAt > 0.18 || contacts.count == 4 ||
                contacts.contains(where: { contact in !anchors.contains(where: { $0.id == contact.id }) }) { cancel() }
            return nil
        }
        guard time - started <= 1.5 else { cancel(); return nil }
        if contacts.count < 4 {
            guard contacts.allSatisfy({ contact in anchors.contains(where: { $0.id == contact.id }) }) else { cancel(); return nil }
            phase = .lifting; liftingAt = time
            return nil
        }
        var movements: [(Double, Double)] = []
        movements.reserveCapacity(4)
        for contact in contacts {
            guard let origin = anchors.first(where: { $0.id == contact.id }) else { cancel(); return nil }
            movements.append((contact.x - origin.x, contact.y - origin.y))
        }
        dx = movements.reduce(0) { $0 + $1.0 } / 4
        dy = movements.reduce(0) { $0 + $1.1 } / 4
        // Reject vertical excursions and pinch/rotation/asymmetric finger motion permanently.
        if abs(dy) > 0.065 || movements.contains(where: { hypot($0.0 - dx, $0.1 - dy) > 0.045 }) {
            cancel()
        }
        return nil
    }
}

public struct TrackpadCommand: Codable {
    public var version = 1
    public var generation: String
    public var active: Bool
    public var sensitivity: SwipeSensitivity
    public var reversed: Bool
    public init(generation: String, active: Bool, settings: TrackpadGestureSettings) {
        self.generation = generation; self.active = active
        sensitivity = settings.sensitivity; reversed = settings.reversed
    }
}

public struct TrackpadReply: Codable {
    public enum Kind: String, Codable { case ready, devices, swipe, failure }
    public var version = 1
    public var kind: Kind
    public var generation: String
    public var direction: TabSwipe?
    public var deviceCount: Int?
    public var uptime: Double?
    public init(_ kind: Kind, generation: String = "", direction: TabSwipe? = nil, deviceCount: Int? = nil, uptime: Double? = nil) {
        self.kind = kind; self.generation = generation; self.direction = direction
        self.deviceCount = deviceCount; self.uptime = uptime
    }
}

/// Both pipe endpoints fail closed on oversized or malformed messages.
public struct GestureLineBuffer {
    private var remainder = Data()
    public init() {}
    public mutating func consume(_ chunk: Data) throws -> [Data] {
        guard chunk.count <= 8_192, remainder.count + chunk.count <= 8_192 else { throw CocoaError(.fileReadTooLarge) }
        remainder.append(chunk)
        var lines: [Data] = []
        while let end = remainder.firstIndex(of: 10) {
            let line = remainder.prefix(upTo: end)
            guard !line.isEmpty, line.count <= 1_024 else { throw CocoaError(.fileReadCorruptFile) }
            lines.append(Data(line)); remainder.removeSubrange(...end)
        }
        guard remainder.count <= 1_024 else { throw CocoaError(.fileReadTooLarge) }
        return lines
    }
}

import Foundation
import CoreAudio
import Darwin

private final class TypingResourcesMarker: NSObject {}

public enum MechanicalKeySound {
    public static let names = ["Gateron Ink Red", "Cherry MX Blue", "Cherry MX Brown", "Gateron Ink Black", "NK Cream", "Holy Panda", "Alpaca", "Topre"]
    public static let defaultName = names[0]
    private static let packs = ["redink", "mxblue", "mxbrown", "blackink", "cream", "holypanda", "alpaca", "topre"]
    public static func character(for name: String) -> String {
        switch name {
        case "Cherry MX Blue": return "Clicky · crisp"
        case "Cherry MX Brown", "Holy Panda": return "Tactile · rounded"
        case "Topre": return "Electrocapacitive · soft"
        default: return "Linear · smooth"
        }
    }
    // Resolve the same bundled resources for the app, its isolated CLI helper and SwiftPM tests.
    // Missing assets return nil, never a runtime resource-accessor fatalError.
    private static let resourceBundle: Bundle? = {
        let name = "ThermoBar_TypingFeedbackProtocol.bundle"
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.bundleURL.deletingLastPathComponent(), executable,
                     Bundle(for: TypingResourcesMarker.self).bundleURL.deletingLastPathComponent(),
                     executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")]
        return roots.compactMap { $0 }.compactMap { Bundle(url: $0.appendingPathComponent(name)) }.first
    }()
    public static func urls(for name: String) -> [URL] {
        guard let index = names.firstIndex(of: name), let root = resourceBundle?.resourceURL?.appendingPathComponent("KeyboardSounds") else { return [] }
        return (0..<3).map { root.appendingPathComponent("\(packs[index])-\($0).mp3") }
    }
    public static func url(for name: String) -> URL? {
        urls(for: name).first
    }
}

public struct TypingFeedbackSettings: Codable, Equatable {
    public var enabled = false
    public var sound = MechanicalKeySound.defaultName
    public var volume: Float = 0.15
    public var confirmedHeadphoneUIDs: [String] = []
    public init() {}
    public mutating func sanitize() {
        if !MechanicalKeySound.names.contains(sound) { sound = MechanicalKeySound.defaultName }
        volume = volume.isFinite ? min(0.5, max(0, volume)) : 0.15
        confirmedHeadphoneUIDs = Array(Set(confirmedHeadphoneUIDs.filter { !$0.isEmpty && $0.count < 512 })).sorted().prefix(16).map { $0 }
    }
}

public struct TypingOutput: Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: UInt32
    public let terminals: [UInt32]
    public var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    public var isHeadphones: Bool { terminals.contains(kAudioStreamTerminalTypeHeadphones) }
    public var isKnownSpeaker: Bool { terminals.contains(kAudioStreamTerminalTypeSpeaker) }
    public func isAllowed(confirmed: [String]) -> Bool {
        isBluetooth && !isKnownSpeaker && (isHeadphones || confirmed.contains(uid))
    }
    public init(id: AudioObjectID, uid: String, name: String, transport: UInt32, terminals: [UInt32]) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport; self.terminals = terminals
    }
}

/// Reads only the selected output. No device discovery, Bluetooth pairing or default-output writes.
public enum TypingOutputInventory {
    public static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        return storage.load(as: T.self)
    }
    public static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    public static func defaultOutput() -> TypingOutput? {
        guard let device = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self),
              device != kAudioObjectUnknown,
              scalar(device, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) == 1,
              let uid = string(device, kAudioDevicePropertyDeviceUID),
              let name = string(device, kAudioObjectPropertyName),
              let transport = scalar(device, kAudioDevicePropertyTransportType, as: UInt32.self) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0, size <= 256 else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        let terminals = streams.compactMap { scalar($0, kAudioStreamPropertyTerminalType, as: UInt32.self) }
        return TypingOutput(id: device, uid: uid, name: name, transport: transport, terminals: terminals)
    }
}

/// Fixed-size datagrams contain no characters, key codes, modifiers or typing history.
public enum TypingFeedbackPacket {
    /// Stack-only, nonblocking hot path. No typed content and no main-queue hop.
    public static func sendPulse(to descriptor: Int32, at uptime: Double, isPreview: Bool = false) {
        guard descriptor >= 0 else { return }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 9) { bytes in
            bytes[0] = isPreview ? 0x50 : 0x4B
            var timestamp = uptime
            withUnsafeBytes(of: &timestamp) { raw in
                bytes.baseAddress!.advanced(by: 1).update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 8)
            }
            _ = Darwin.send(descriptor, bytes.baseAddress, 9, MSG_DONTWAIT)
        }
    }
    public static func pulse(at uptime: Double, isPreview: Bool = false) -> Data {
        var value = uptime
        var data = Data([isPreview ? 0x50 : 0x4B])
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }
    public static func freshPulse(_ data: Data, now: Double) -> Bool {
        guard data.count == 9, data.first == 0x4B || data.first == 0x50 else { return false }
        let timestamp = data.dropFirst().withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        return timestamp.isFinite && (0...0.05).contains(now - timestamp)
    }
}

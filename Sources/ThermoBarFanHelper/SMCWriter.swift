import Foundation
import IOKit
import FanControlProtocol

/// Write access is intentionally confined to the privileged helper process.
final class SMCWriter {
    enum Error: Swift.Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case keyNotFound(String)
        case callFailed(key: String, ioResult: kern_return_t, smcResult: UInt8)
        case malformedValue(String)
        case unsupportedType(key: String, type: String)
        case invalidTarget(String)

        var description: String {
            switch self {
            case .serviceNotFound: return "AppleSMC service not found"
            case .openFailed(let code): return "Unable to open AppleSMC (0x\(String(code, radix: 16)))"
            case .keyNotFound(let key): return "SMC key \(key) not found"
            case .callFailed(let key, let io, let smc):
                return "SMC operation failed for \(key) (IO 0x\(String(io, radix: 16)), SMC \(smc))"
            case .malformedValue(let key): return "SMC key \(key) returned malformed data"
            case .unsupportedType(let key, let type): return "SMC key \(key) uses unsupported type \(type)"
            case .invalidTarget(let message): return message
            }
        }
    }

    private struct KeyInfo {
        let size: Int
        let type: String
    }

    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let bytes = 48
    }

    private enum Command {
        static let readBytes: UInt8 = 5
        static let writeBytes: UInt8 = 6
        static let readKeyInfo: UInt8 = 9
    }

    private static let structSize = 80
    private static let selector: UInt32 = 2
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: KeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw Error.serviceNotFound }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == kIOReturnSuccess else { throw Error.openFailed(result) }
        connection = opened
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func capabilities() throws -> [FanCapability] {
        let declared = Int((try readNumber("FNum")).rounded())
        guard (1...8).contains(declared) else { throw Error.malformedValue("FNum") }

        return try (0..<declared).map { index in
            let lower = "F\(index)md"
            let upper = "F\(index)Md"
            let modeKey: String
            if keyExists(lower) {
                modeKey = lower
            } else if keyExists(upper) {
                modeKey = upper
            } else {
                throw Error.keyNotFound(lower)
            }

            let minimum = try readNumber("F\(index)Mn")
            let maximum = try readNumber("F\(index)Mx")
            guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum else {
                throw Error.malformedValue("F\(index)Mn/F\(index)Mx")
            }
            return FanCapability(index: index, minimumRPM: minimum, maximumRPM: maximum, modeKey: modeKey)
        }
    }

    func apply(_ requested: [FanTarget], capabilities: [FanCapability]) throws -> [FanTarget] {
        guard !requested.isEmpty else { throw Error.invalidTarget("No fan targets supplied") }
        guard Set(requested.map(\.index)).count == requested.count else {
            throw Error.invalidTarget("Duplicate fan target")
        }

        let byIndex = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.index, $0) })
        let clamped = try requested.map { target -> FanTarget in
            guard target.rpm.isFinite, let fan = byIndex[target.index] else {
                throw Error.invalidTarget("Invalid fan \(target.index) target")
            }
            return FanTarget(index: target.index, rpm: min(fan.maximumRPM, max(fan.minimumRPM, target.rpm)))
        }

        do {
            for target in clamped {
                let fan = byIndex[target.index]!
                try writeNumber(fan.modeKey, value: 1)
                try writeNumber("F\(target.index)Tg", value: target.rpm)
            }
            return clamped
        } catch {
            restoreSystem(capabilities: capabilities)
            throw error
        }
    }

    func restoreSystem(capabilities: [FanCapability]) {
        for fan in capabilities {
            try? writeNumber(fan.modeKey, value: 0)
        }
    }

    private func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    private func keyInfo(_ key: String) throws -> KeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putNativeUInt32(&input, at: Offset.key, value: Self.fourCC(key))
        input[Offset.command] = Command.readKeyInfo
        let output: [UInt8]
        do { output = try call(input, key: key) } catch { throw Error.keyNotFound(key) }
        let info = KeyInfo(
            size: Int(Self.nativeUInt32(output, at: Offset.dataSize)),
            type: Self.fourCCString(Self.nativeUInt32(output, at: Offset.dataType))
        )
        keyInfoCache[key] = info
        return info
    }

    private func readNumber(_ key: String) throws -> Double {
        let info = try keyInfo(key)
        let bytes = try readBytes(key, info: info)
        switch info.type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard bytes.count >= 4 else { throw Error.malformedValue(key) }
            let bits = UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { throw Error.malformedValue(key) }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8":
            guard let first = bytes.first else { throw Error.malformedValue(key) }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { throw Error.malformedValue(key) }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            throw Error.unsupportedType(key: key, type: info.type)
        }
    }

    private func writeNumber(_ key: String, value: Double) throws {
        let info = try keyInfo(key)
        let type = info.type.trimmingCharacters(in: .whitespaces)
        let bytes: [UInt8]
        switch type {
        case "flt":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            let raw = UInt16(max(0, min(Double(UInt16.max) / 4, value)) * 4)
            bytes = [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "ui8":
            bytes = [UInt8(max(0, min(255, value)).rounded())]
        case "ui16":
            let raw = UInt16(max(0, min(Double(UInt16.max), value)).rounded())
            bytes = [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        default:
            throw Error.unsupportedType(key: key, type: info.type)
        }
        guard bytes.count == info.size else { throw Error.malformedValue(key) }

        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putNativeUInt32(&input, at: Offset.key, value: Self.fourCC(key))
        Self.putNativeUInt32(&input, at: Offset.dataSize, value: UInt32(info.size))
        input[Offset.command] = Command.writeBytes
        for (index, byte) in bytes.enumerated() { input[Offset.bytes + index] = byte }
        _ = try call(input, key: key)
    }

    private func readBytes(_ key: String, info: KeyInfo) throws -> [UInt8] {
        guard (1...32).contains(info.size) else { throw Error.malformedValue(key) }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putNativeUInt32(&input, at: Offset.key, value: Self.fourCC(key))
        Self.putNativeUInt32(&input, at: Offset.dataSize, value: UInt32(info.size))
        input[Offset.command] = Command.readBytes
        let output = try call(input, key: key)
        return Array(output[Offset.bytes..<(Offset.bytes + info.size)])
    }

    private func call(_ input: [UInt8], key: String) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let ioResult = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(
                    connection, Self.selector, inputPointer.baseAddress!, Self.structSize,
                    outputPointer.baseAddress!, &outputSize
                )
            }
        }
        let smcResult = output[Offset.result]
        guard ioResult == kIOReturnSuccess, smcResult == 0 else {
            throw Error.callFailed(key: key, ioResult: ioResult, smcResult: smcResult)
        }
        guard outputSize >= Self.structSize else { throw Error.malformedValue(key) }
        return output
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCCString(_ value: UInt32) -> String {
        String(bytes: [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? "????"
    }

    private static func putNativeUInt32(_ buffer: inout [UInt8], at offset: Int, value: UInt32) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func nativeUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8 | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }
}

import Foundation
import IOKit

/// Read-only access to Apple's undocumented SMC key-value interface.
///
/// The wire layout and decoding are adapted from the MIT-licensed Fan Control
/// project by Adil Kairolla. See THIRD_PARTY_NOTICES.md in the app bundle.
final class SMC {
    enum Error: Swift.Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case keyNotFound(String)
        case callFailed(key: String, ioResult: kern_return_t, smcResult: UInt8)
        case malformedValue(key: String)
        case unsupportedType(key: String, type: String)

        var description: String {
            switch self {
            case .serviceNotFound:
                return "AppleSMC service not found"
            case .openFailed(let code):
                return "Unable to open AppleSMC (0x\(String(code, radix: 16)))"
            case .keyNotFound(let key):
                return "SMC key \(key) not found"
            case .callFailed(let key, let ioResult, let smcResult):
                return "Failed to read \(key) (IO 0x\(String(ioResult, radix: 16)), SMC \(smcResult))"
            case .malformedValue(let key):
                return "SMC key \(key) returned malformed data"
            case .unsupportedType(let key, let type):
                return "SMC key \(key) uses unsupported type \(type)"
            }
        }
    }

    struct KeyInfo {
        let size: Int
        let type: String
    }

    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let bytes = 48
    }

    private enum Command {
        static let readBytes: UInt8 = 5
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    private static let structSize = 80
    private static let selector: UInt32 = 2

    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: KeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw Error.serviceNotFound }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        guard result == kIOReturnSuccess else { throw Error.openFailed(result) }
        connection = openedConnection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func keyInfo(_ key: String) throws -> KeyInfo {
        if let cached = keyInfoCache[key] {
            return cached
        }

        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putNativeUInt32(&input, at: Offset.key, value: Self.fourCC(key))
        input[Offset.command] = Command.readKeyInfo

        let output: [UInt8]
        do {
            output = try call(input, key: key)
        } catch {
            throw Error.keyNotFound(key)
        }

        let info = KeyInfo(
            size: Int(Self.nativeUInt32(output, at: Offset.dataSize)),
            type: Self.fourCCString(Self.nativeUInt32(output, at: Offset.dataType))
        )
        keyInfoCache[key] = info
        return info
    }

    func allKeys() throws -> [String] {
        let countBytes = try readBytes("#KEY")
        guard countBytes.count >= 4 else { throw Error.malformedValue(key: "#KEY") }
        let total = Int(Self.bigEndianUInt32(countBytes))

        var keys: [String] = []
        keys.reserveCapacity(total)
        for index in 0..<total {
            var input = [UInt8](repeating: 0, count: Self.structSize)
            input[Offset.command] = Command.readIndex
            Self.putNativeUInt32(&input, at: Offset.index, value: UInt32(index))
            guard let output = try? call(input, key: "#KEY[\(index)]") else { continue }
            keys.append(Self.fourCCString(Self.nativeUInt32(output, at: Offset.key)))
        }
        return keys
    }

    func readNumber(_ key: String) throws -> Double {
        let info = try keyInfo(key)
        return try Self.decode(bytes: readBytes(key), type: info.type, key: key)
    }

    static func decode(bytes: [UInt8], type rawType: String, key: String = "test") throws -> Double {
        let type = rawType.trimmingCharacters(in: .whitespaces)

        func require(_ count: Int) throws {
            guard bytes.count >= count else { throw Error.malformedValue(key: key) }
        }

        switch type {
        case "flt":
            try require(4)
            let bits = UInt32(bytes[3]) << 24
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[0])
            return Double(Float(bitPattern: bits))
        case "sp78":
            try require(2)
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2":
            try require(2)
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "ui8":
            try require(1)
            return Double(bytes[0])
        case "ui16":
            try require(2)
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            try require(4)
            return Double(Self.bigEndianUInt32(bytes))
        default:
            throw Error.unsupportedType(key: key, type: rawType)
        }
    }

    private func readBytes(_ key: String) throws -> [UInt8] {
        let info = try keyInfo(key)
        guard (1...32).contains(info.size) else { throw Error.malformedValue(key: key) }

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
                    connection,
                    Self.selector,
                    inputPointer.baseAddress!,
                    Self.structSize,
                    outputPointer.baseAddress!,
                    &outputSize
                )
            }
        }

        let smcResult = output[Offset.result]
        guard ioResult == kIOReturnSuccess, smcResult == 0 else {
            throw Error.callFailed(key: key, ioResult: ioResult, smcResult: smcResult)
        }
        guard outputSize >= Self.structSize else { throw Error.malformedValue(key: key) }
        return output
    }

    private static func fourCC(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in text.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// The 80-byte request struct uses the host's native little-endian layout.
    private static func putNativeUInt32(_ buffer: inout [UInt8], at offset: Int, value: UInt32) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func nativeUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    private static func bigEndianUInt32(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }
}

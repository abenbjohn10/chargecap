import Foundation
import IOKit

/// Minimal AppleSMC client. Same transport AlDente's helper uses
/// (IOServiceOpen("AppleSMC") + IOConnectCallStructMethod, selector 2 = kSMCHandleYPCEvent).
///
/// The kernel expects an 80-byte SMCParamStruct. Rather than rely on Swift struct
/// layout, fields are written at their C offsets:
///   0  key (UInt32)            28 keyInfo.dataSize (UInt32)
///   32 keyInfo.dataType        36 keyInfo.dataAttributes
///   40 result  41 status  42 data8 (command)  44 data32  48..79 bytes[32]
public final class SMC {
    public enum SMCError: Error, CustomStringConvertible {
        case driverNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case keyNotFound(String)
        case smcResult(String, UInt8)
        case badSize(String, expected: Int, got: Int)

        public var description: String {
            switch self {
            case .driverNotFound: return "AppleSMC driver not found"
            case .openFailed(let r): return String(format: "IOServiceOpen failed: 0x%08x", r)
            case .callFailed(let r): return String(format: "IOConnectCallStructMethod failed: 0x%08x (root required for writes)", r)
            case .keyNotFound(let k): return "SMC key \(k) not found"
            case .smcResult(let k, let r): return String(format: "SMC key %@ returned result 0x%02x", k, r)
            case .badSize(let k, let e, let g): return "SMC key \(k): expected \(e) bytes, got \(g)"
            }
        }
    }

    public struct KeyInfo {
        public let size: Int
        public let type: String
    }

    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }

    private static let structSize = 80
    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let resultKeyNotFound: UInt8 = 0x84

    private var connection: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]
    private let lock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard r == kIOReturnSuccess else { throw SMCError.openFailed(r) }
    }

    deinit { IOServiceClose(connection) }

    // MARK: Public API

    public func info(_ key: String) throws -> KeyInfo {
        try lock.withLock {
            if let cached = infoCache[key] { return cached }
            var input = [UInt8](repeating: 0, count: Self.structSize)
            Self.put32(&input, 0, Self.fourCC(key))
            input[42] = Command.getKeyInfo.rawValue
            let out = try call(input, key: key)
            let info = KeyInfo(size: Int(Self.get32(out, 28)), type: Self.string(Self.get32(out, 32)))
            infoCache[key] = info
            return info
        }
    }

    public func exists(_ key: String) -> Bool {
        (try? info(key)) != nil
    }

    public func read(_ key: String) throws -> [UInt8] {
        let info = try info(key)
        return try lock.withLock {
            var input = [UInt8](repeating: 0, count: Self.structSize)
            Self.put32(&input, 0, Self.fourCC(key))
            Self.put32(&input, 28, UInt32(info.size))
            input[42] = Command.readKey.rawValue
            let out = try call(input, key: key)
            return Array(out[48..<(48 + min(info.size, 32))])
        }
    }

    /// Writes require root. Value size must match the key's declared size.
    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let info = try info(key)
        guard bytes.count == info.size else { throw SMCError.badSize(key, expected: info.size, got: bytes.count) }
        try lock.withLock {
            var input = [UInt8](repeating: 0, count: Self.structSize)
            Self.put32(&input, 0, Self.fourCC(key))
            Self.put32(&input, 28, UInt32(info.size))
            input[42] = Command.writeKey.rawValue
            for (i, b) in bytes.enumerated() { input[48 + i] = b }
            _ = try call(input, key: key)
        }
    }

    /// Every key the SMC exposes (`#KEY` holds the count).
    public func allKeys() throws -> [String] {
        let countBytes = try read("#KEY")
        let count = countBytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        return try (0..<count).map { index in
            try lock.withLock {
                var input = [UInt8](repeating: 0, count: Self.structSize)
                Self.put32(&input, 44, UInt32(index))
                input[42] = Command.getKeyFromIndex.rawValue
                let out = try call(input, key: "#\(index)")
                return Self.string(Self.get32(out, 0))
            }
        }
    }

    // MARK: Transport

    private func call(_ input: [UInt8], key: String) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outSize = Self.structSize
        let r = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(connection, Self.kSMCHandleYPCEvent,
                                          inp.baseAddress, Self.structSize, out.baseAddress, &outSize)
            }
        }
        guard r == kIOReturnSuccess else { throw SMCError.callFailed(r) }
        switch output[40] {
        case 0: return output
        case Self.resultKeyNotFound: throw SMCError.keyNotFound(key)
        case let other: throw SMCError.smcResult(key, other)
        }
    }

    // MARK: Helpers

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
    }

    private static func put32(_ buf: inout [UInt8], _ offset: Int, _ v: UInt32) {
        // SMCParamStruct is little-endian in memory on both Intel and Apple Silicon.
        withUnsafeBytes(of: v.littleEndian) { for (i, b) in $0.enumerated() { buf[offset + i] = b } }
    }

    private static func get32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        buf[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
}

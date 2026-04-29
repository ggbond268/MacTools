import Foundation
import IOKit

final class SystemStatusSMCReader {
    private enum Selector: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case readKeyInfo = 9
    }

    private struct KeyData {
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct LimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuLimit: UInt32 = 0
            var gpuLimit: UInt32 = 0
            var memoryLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private struct Value {
        let key: String
        var dataSize: UInt32 = 0
        var dataType = ""
        var bytes = [UInt8](repeating: 0, count: 32)
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess, connection != 0 else {
            return nil
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func value(for key: String) -> Double? {
        guard key.count == 4 else {
            return nil
        }

        var value = Value(key: key)
        guard read(&value) == kIOReturnSuccess, value.dataSize > 0 else {
            return nil
        }
        guard value.bytes.contains(where: { $0 != 0 }) else {
            return nil
        }

        switch value.dataType {
        case "ui8 ":
            return Double(value.bytes[0])
        case "ui16":
            return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
        case "ui32":
            return Double(
                UInt32(value.bytes[0]) << 24 |
                UInt32(value.bytes[1]) << 16 |
                UInt32(value.bytes[2]) << 8 |
                UInt32(value.bytes[3])
            )
        case "sp78":
            let rawValue = Double(Int(value.bytes[0]) * 256 + Int(value.bytes[1]))
            return rawValue / 256
        case "flt ":
            var floatValue: Float = 0
            withUnsafeMutableBytes(of: &floatValue) { pointer in
                pointer.copyBytes(from: value.bytes.prefix(4))
            }
            return Double(floatValue)
        case "fpe2":
            return Double((Int(value.bytes[0]) << 6) + (Int(value.bytes[1]) >> 2))
        default:
            return nil
        }
    }

    private func read(_ value: inout Value) -> kern_return_t {
        var input = KeyData()
        var output = KeyData()

        input.key = Self.fourCharCode(value.key)
        input.data8 = Selector.readKeyInfo.rawValue

        var result = call(Selector.kernelIndex.rawValue, input: &input, output: &output)
        guard result == kIOReturnSuccess else {
            return result
        }

        value.dataSize = UInt32(output.keyInfo.dataSize)
        value.dataType = Self.string(from: output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = Selector.readBytes.rawValue

        result = call(Selector.kernelIndex.rawValue, input: &input, output: &output)
        guard result == kIOReturnSuccess else {
            return result
        }

        withUnsafeBytes(of: output.bytes) { rawBuffer in
            let count = min(Int(value.dataSize), rawBuffer.count, value.bytes.count)
            value.bytes.replaceSubrange(0..<count, with: rawBuffer.prefix(count))
        }

        return kIOReturnSuccess
    }

    private func call(_ selector: UInt8, input: inout KeyData, output: inout KeyData) -> kern_return_t {
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(connection, UInt32(selector), &input, inputSize, &output, &outputSize)
    }

    private static func fourCharCode(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { result, character in
            result << 8 | UInt32(character)
        }
    }

    private static func string(from value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

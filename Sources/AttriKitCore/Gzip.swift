import Foundation

enum Gzip {
    static func compress(_ input: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        if input.isEmpty {
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
        } else {
            var offset = 0
            while offset < input.count {
                let length = min(65_535, input.count - offset)
                let final: UInt8 = offset + length == input.count ? 0x01 : 0x00
                output.append(final)
                let value = UInt16(length)
                let inverse = ~value
                output.append(UInt8(value & 0xff))
                output.append(UInt8(value >> 8))
                output.append(UInt8(inverse & 0xff))
                output.append(UInt8(inverse >> 8))
                output.append(input.subdata(in: offset..<(offset + length)))
                offset += length
            }
        }
        appendLittleEndian(crc32(input), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: input.count), to: &output)
        return output
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

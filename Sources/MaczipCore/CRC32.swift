import Foundation
import zlib

public enum CRC32 {
    /// `crc`에 `data`를 이어서 갱신한다. 시작값은 0.
    public static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = uLong(crc)
        data.withUnsafeBytes { raw in
            var p = raw.bindMemory(to: Bytef.self).baseAddress
            var remaining = raw.count
            while remaining > 0, let base = p {
                let n = min(remaining, Int(UInt32.max))
                c = zlib.crc32(c, base, uInt(n))
                p = base + n
                remaining -= n
            }
        }
        return UInt32(truncatingIfNeeded: c)
    }

    public static func checksum(_ data: Data) -> UInt32 { update(0, data) }

    /// 1바이트 CRC 갱신(ZipCrypto 키 갱신용).
    static func step(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
}

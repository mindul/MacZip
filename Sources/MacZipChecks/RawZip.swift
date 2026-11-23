import Foundation
import MacZipCore

/// 테스트 전용: 이름 바이트·플래그·확장 필드를 그대로 쓰는 최소 zip 생성기(항상 store).
struct RawZipEntry {
    var nameBytes: [UInt8]
    var flags: UInt16 = 0
    var data: Data = Data()
    var extra: [UInt8] = []
    var unixMode: UInt16? = nil
    var crcOverride: UInt32? = nil
    var passwordBytes: [UInt8]? = nil
    var method: UInt16 = 0
    /// 중앙 디렉터리·로컬 헤더에 적을 해제 크기를 속인다(zip bomb 재현).
    var usizeOverride: UInt32? = nil
    /// 암호화 후 페이로드의 이 위치 바이트를 뒤집는다(손상 재현).
    var corruptPayloadAt: Int? = nil
}

private extension Data {
    mutating func w16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func w32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

func buildRawZip(_ entries: [RawZipEntry]) -> Data {
    var out = Data(), central = Data()
    let time: UInt16 = 0x6000, date: UInt16 = 0x5A21   // 2025-01-01 12:00
    for e in entries {
        let crc = e.crcOverride ?? CRC32.checksum(e.data)
        var flags = e.flags
        var payload = e.data
        if let pw = e.passwordBytes {
            flags |= 0x1
            // 헤더 난수를 고정해 검사 결과가 매번 같게 한다.
            var enc = ZipCryptoEncryptor(password: pw, checkByte: UInt8(truncatingIfNeeded: crc >> 24),
                                         random: Array(1...11))
            enc.encrypt(&payload)
            payload = Data(enc.header) + payload
        }
        if let i = e.corruptPayloadAt { payload[payload.startIndex + i] ^= 0xFF }
        let usize = e.usizeOverride ?? UInt32(e.data.count)
        let offset = UInt32(out.count)
        out.w32(0x0403_4B50); out.w16(20); out.w16(flags); out.w16(e.method); out.w16(time); out.w16(date)
        out.w32(crc); out.w32(UInt32(payload.count)); out.w32(usize)
        out.w16(UInt16(e.nameBytes.count)); out.w16(UInt16(e.extra.count))
        out.append(contentsOf: e.nameBytes); out.append(contentsOf: e.extra); out.append(payload)

        central.w32(0x0201_4B50); central.w16(e.unixMode == nil ? 20 : (3 << 8 | 20)); central.w16(20)
        central.w16(flags); central.w16(e.method); central.w16(time); central.w16(date)
        central.w32(crc); central.w32(UInt32(payload.count)); central.w32(usize)
        central.w16(UInt16(e.nameBytes.count)); central.w16(UInt16(e.extra.count)); central.w16(0); central.w16(0); central.w16(0)
        central.w32(UInt32(e.unixMode ?? 0) << 16); central.w32(offset)
        central.append(contentsOf: e.nameBytes); central.append(contentsOf: e.extra)
    }
    let cdOffset = UInt32(out.count)
    out.append(central)
    out.w32(0x0605_4B50); out.w16(0); out.w16(0)
    out.w16(UInt16(entries.count)); out.w16(UInt16(entries.count))
    out.w32(UInt32(central.count)); out.w32(cdOffset); out.w16(0)
    return out
}

/// Info-ZIP Unicode Path 확장 필드(0x7075).
func unicodePathExtra(rawName: [UInt8], name: String) -> [UInt8] {
    let utf8 = Array(name.utf8)
    var d = Data()
    d.w16(0x7075); d.w16(UInt16(1 + 4 + utf8.count))
    d.append(1); d.w32(CRC32.checksum(Data(rawName))); d.append(contentsOf: utf8)
    return Array(d)
}

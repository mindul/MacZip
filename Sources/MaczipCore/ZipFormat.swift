import Foundation

/// zip 레코드 시그니처와 리틀엔디언·DOS 시간 도우미(Writer/Reader 공용).
enum ZipSig {
    static let local: UInt32 = 0x0403_4B50
    static let central: UInt32 = 0x0201_4B50
    static let end: UInt32 = 0x0605_4B50
    static let descriptor: UInt32 = 0x0807_4B50
}

enum ZipFlag {
    static let encrypted: UInt16 = 0x0001
    static let dataDescriptor: UInt16 = 0x0008
    static let utf8: UInt16 = 0x0800
}

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    func u16(at i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(at i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }
}

enum DosTime {
    /// (time, date) — 로컬 시간 기준, 1980년 이전은 1980-01-01로 맞춘다.
    static func encode(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, y >= 1980, y <= 2107 else { return (0, (0 << 9) | (1 << 5) | 1) }
        let t = UInt16(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
        let d = UInt16((y - 1980) << 9 | c.month! << 5 | c.day!)
        return (t, d)
    }

    static func decode(time: UInt16, date: UInt16) -> Date {
        var c = DateComponents()
        c.year = Int(date >> 9) + 1980
        c.month = max(1, Int((date >> 5) & 0xF))
        c.day = max(1, Int(date & 0x1F))
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 315_532_800)
    }
}

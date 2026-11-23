import Foundation
import Security

/// PKWARE 전통 암호화(ZipCrypto)의 키 상태.
struct ZipCryptoKeys {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890

    init(password: [UInt8]) {
        for b in password { update(b) }
    }

    mutating func update(_ b: UInt8) {
        k0 = CRC32.step(k0, b)
        k1 = (k1 &+ (k0 & 0xFF)) &* 134_775_813 &+ 1
        k2 = CRC32.step(k2, UInt8(truncatingIfNeeded: k1 >> 24))
    }

    var streamByte: UInt8 {
        let t = UInt16(truncatingIfNeeded: k2 | 2)
        return UInt8(truncatingIfNeeded: (UInt32(t) &* UInt32(t ^ 1)) >> 8)
    }

    mutating func encrypt(_ p: UInt8) -> UInt8 {
        let c = p ^ streamByte
        update(p)
        return c
    }

    mutating func decrypt(_ c: UInt8) -> UInt8 {
        let p = c ^ streamByte
        update(p)
        return p
    }
}

public struct ZipCryptoEncryptor {
    private var keys: ZipCryptoKeys
    /// 암호화된 12바이트 헤더. 데이터 앞에 그대로 쓴다.
    public let header: [UInt8]

    public init(password: [UInt8], checkByte: UInt8, random: [UInt8]? = nil) {
        var keys = ZipCryptoKeys(password: password)
        var plainHeader: [UInt8]
        if let random, random.count >= 11 {
            plainHeader = Array(random.prefix(11))
        } else {
            plainHeader = [UInt8](repeating: 0, count: 11)
            if SecRandomCopyBytes(kSecRandomDefault, 11, &plainHeader) != errSecSuccess {
                plainHeader = (0..<11).map { _ in UInt8.random(in: 0...255) }
            }
        }
        plainHeader.append(checkByte)
        self.header = plainHeader.map { keys.encrypt($0) }
        self.keys = keys
    }

    public mutating func encrypt(_ data: inout Data) {
        for i in data.indices { data[i] = keys.encrypt(data[i]) }
    }
}

public struct ZipCryptoDecryptor {
    private var keys: ZipCryptoKeys
    /// 복호화된 헤더의 마지막 바이트.
    public let checkByte: UInt8

    public init(password: [UInt8], header: [UInt8]) {
        var keys = ZipCryptoKeys(password: password)
        var last: UInt8 = 0
        for b in header.prefix(12) { last = keys.decrypt(b) }
        self.checkByte = last
        self.keys = keys
    }

    public mutating func decrypt(_ data: inout Data) {
        for i in data.indices { data[i] = keys.decrypt(data[i]) }
    }
}

public enum ZipPassword {
    /// 비밀번호 바이트 후보: UTF-8, 그리고 (다르고 표현 가능하면) CP949.
    public static func candidates(_ password: String) -> [[UInt8]] {
        let utf8 = Array(password.utf8)
        var result = [utf8]
        if let cp949 = password.data(using: TextEncodings.cp949, allowLossyConversion: false) {
            let bytes = Array(cp949)
            if bytes != utf8 { result.append(bytes) }
        }
        return result
    }
}

enum TextEncodings {
    static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
}

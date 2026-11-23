import CommonCrypto
import Foundation
import Security

/// 압축할 때 쓸 암호 방식.
public enum EncryptionMethod: Sendable, Equatable {
    /// WinZip AES-256 (AE-2). 반디집·7-Zip·WinRAR 등에서 열림.
    case aes256
    /// PKWARE 전통 암호화. 윈도우 기본 탐색기에서도 열리지만 약함.
    case zipCrypto
}

/// WinZip AES 규격(AE-1/AE-2): PBKDF2-HMAC-SHA1(1000회) 키 유도, AES-CTR(리틀엔디언 카운터, 1부터), HMAC-SHA1 인증 코드 10바이트.
enum WinZipAES {
    static let iterations: UInt32 = 1000
    static let verifierLength = 2
    static let authCodeLength = 10
    static let extraID: UInt16 = 0x9901

    /// 강도(1=128, 2=192, 3=256) → (키 길이, 솔트 길이)
    static func sizes(strength: UInt8) -> (key: Int, salt: Int)? {
        switch strength {
        case 1: return (16, 8)
        case 2: return (24, 12)
        case 3: return (32, 16)
        default: return nil
        }
    }

    struct Keys {
        let aesKey: [UInt8]
        let macKey: [UInt8]
        let verifier: [UInt8]
    }

    static func deriveKeys(password: [UInt8], salt: [UInt8], keyLength: Int) -> Keys {
        var out = [UInt8](repeating: 0, count: keyLength * 2 + verifierLength)
        let rc = password.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: CChar.self) { pwc in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwc.baseAddress, pw.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     iterations, &out, out.count)
            }
        }
        precondition(rc == kCCSuccess, "PBKDF2 실패: \(rc)")
        return Keys(aesKey: Array(out[0..<keyLength]),
                    macKey: Array(out[keyLength..<(keyLength * 2)]),
                    verifier: Array(out[(keyLength * 2)...]))
    }

    static func randomSalt(length: Int) -> [UInt8] {
        var salt = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &salt) != errSecSuccess {
            salt = (0..<length).map { _ in UInt8.random(in: 0...255) }
        }
        return salt
    }

    /// 0x9901 확장 필드: 버전(AE-2), "AE", 강도, 실제 압축 방식.
    static func extraField(strength: UInt8, actualMethod: UInt16) -> Data {
        var d = Data()
        d.le16(extraID); d.le16(7)
        d.le16(2); d.append(contentsOf: Array("AE".utf8)); d.append(strength); d.le16(actualMethod)
        return d
    }
}

/// AES-CTR 암·복호화와 HMAC-SHA1(암호문 기준)을 함께 처리하는 스트림.
final class WinZipAESStream {
    private var cryptor: CCCryptorRef?
    private var hmac = CCHmacContext()
    private var counter: UInt64 = 0
    private var keystream: [UInt8] = []
    private var position = 0

    init(keys: WinZipAES.Keys) {
        let rc = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                 keys.aesKey, keys.aesKey.count, nil, &cryptor)
        precondition(rc == kCCSuccess, "AES 초기화 실패: \(rc)")
        CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), keys.macKey, keys.macKey.count)
    }

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    func encrypt(_ data: inout Data) {
        applyKeystream(&data)
        updateMAC(data)
    }

    func decrypt(_ data: inout Data) {
        updateMAC(data)
        applyKeystream(&data)
    }

    /// 인증 코드(HMAC-SHA1 앞 10바이트). 마지막에 한 번만 호출한다.
    func authCode() -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(&hmac, &mac)
        return Array(mac.prefix(WinZipAES.authCodeLength))
    }

    private func updateMAC(_ data: Data) {
        data.withUnsafeBytes { CCHmacUpdate(&hmac, $0.baseAddress, $0.count) }
    }

    private func applyKeystream(_ data: inout Data) {
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                if position == keystream.count { refill(blocks: min(16_384, (bytes.count - i + 15) / 16)) }
                let n = min(bytes.count - i, keystream.count - position)
                for j in 0..<n { bytes[i + j] ^= keystream[position + j] }
                i += n
                position += n
            }
        }
    }

    /// 카운터 블록(128비트 리틀엔디언, 1부터)을 AES로 암호화해 키스트림을 만든다.
    private func refill(blocks: Int) {
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        for b in 0..<blocks {
            counter += 1
            withUnsafeBytes(of: counter.littleEndian) { counters.replaceSubrange((b * 16)..<(b * 16 + 8), with: $0) }
        }
        keystream = [UInt8](repeating: 0, count: counters.count)
        var moved = 0
        let rc = CCCryptorUpdate(cryptor, counters, counters.count, &keystream, keystream.count, &moved)
        precondition(rc == kCCSuccess && moved == counters.count, "AES 실패: \(rc)")
        position = 0
    }
}

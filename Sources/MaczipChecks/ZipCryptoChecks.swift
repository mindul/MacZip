import Foundation
import MaczipCore

func zipCryptoChecks() {
    Harness.suite("ZipCrypto") {
        // CRC32
        Harness.expectEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926, "CRC32 표준 벡터")
        let whole = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let split = CRC32.update(CRC32.update(0, whole.prefix(3333)), whole.dropFirst(3333))
        Harness.expectEqual(split, CRC32.checksum(whole), "CRC32 조각 갱신")

        // 왕복
        let pw = Array("pw1234".utf8)
        for size in [0, 1, 100_000] {
            let plain = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            var enc = ZipCryptoEncryptor(password: pw, checkByte: 0xA7)
            Harness.expectEqual(enc.header.count, 12, "헤더 길이")
            var data = plain
            enc.encrypt(&data)
            if size > 16 { Harness.expect(data != plain, "암호문이 평문과 달라야 함") }
            var dec = ZipCryptoDecryptor(password: pw, header: enc.header)
            Harness.expectEqual(dec.checkByte, 0xA7, "검사 바이트 (\(size))")
            dec.decrypt(&data)
            Harness.expect(data == plain, "왕복 복원 (\(size)바이트)")
        }

        // 틀린 비밀번호는 검사 바이트가 (대부분) 달라야 함
        let enc = ZipCryptoEncryptor(password: pw, checkByte: 0x5C)
        let mismatches = (0..<20).filter { i in
            ZipCryptoDecryptor(password: Array("wrong\(i)".utf8), header: enc.header).checkByte != 0x5C
        }.count
        Harness.expect(mismatches >= 1, "틀린 비밀번호 20개 중 최소 1개는 검사 바이트가 달라야 함")

        // 교차 검증: Python zipfile 복호화기
        let plain = Data("안녕하세요 Maczip ZipCrypto 교차 검증".utf8)
        var e2 = ZipCryptoEncryptor(password: Array("pw".utf8), checkByte: 0x11)
        var body = plain
        e2.encrypt(&body)
        let r = py("import sys, zipfile; d = zipfile._ZipDecrypter(b'pw'); sys.stdout.write(d(sys.stdin.buffer.read())[12:].hex())",
                   [], input: Data(e2.header) + body)
        Harness.expectEqual(r.out, plain.map { String(format: "%02x", $0) }.joined(), "Python 복호화 결과 \(r.err)")

        // 비밀번호 후보
        Harness.expectEqual(ZipPassword.candidates("abc"), [[0x61, 0x62, 0x63]], "ASCII 후보")
        let ko = ZipPassword.candidates("한글")
        Harness.expectEqual(ko.count, 2, "한글 후보 수")
        Harness.expectEqual(ko.first ?? [], Array("한글".utf8), "첫 후보 UTF-8")
        Harness.expectEqual(ko.last?.count ?? 0, 4, "둘째 후보 CP949 4바이트")
        Harness.expectEqual(ZipPassword.candidates("🙂"), [Array("🙂".utf8)], "CP949 불가 문자는 UTF-8만")
    }
}

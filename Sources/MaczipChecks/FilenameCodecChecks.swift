import Foundation
import MaczipCore

private let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

func cp949Bytes(_ s: String) -> [UInt8] { Array(s.data(using: cp949)!) }

func filenameCodecChecks() {
    Harness.suite("FilenameCodec") {
        let nfc = "한글.txt"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        Harness.expect(nfd.unicodeScalars.count != nfc.unicodeScalars.count, "전제: NFD는 스칼라 수가 다름")
        Harness.expectEqual(Array(FilenameCodec.normalizeForArchive(nfd).unicodeScalars),
                            Array(nfc.unicodeScalars), "NFD → NFC")

        func raw(_ b: [UInt8], flag: Bool = false, up: (UInt32, String)? = nil) -> RawEntryName {
            RawEntryName(bytes: b, utf8Flag: flag, unicodePath: up.map { (crc: $0.0, name: $0.1) })
        }
        Harness.expectEqual(FilenameCodec.chooseEncoding([raw(Array(nfc.utf8), flag: true)]), .utf8, "플래그 UTF-8")
        Harness.expectEqual(FilenameCodec.chooseEncoding([raw(Array(nfd.utf8))]), .utf8, "플래그 없는 NFD UTF-8")
        Harness.expectEqual(FilenameCodec.chooseEncoding([raw(cp949Bytes(nfc))]), .cp949, "CP949")
        Harness.expectEqual(FilenameCodec.chooseEncoding([raw(Array("plain.txt".utf8))]), .utf8, "ASCII")
        Harness.expectEqual(FilenameCodec.chooseEncoding([]), .utf8, "항목 없음")

        // 압축 파일 단위 판별: 하나만 CP949여도 전체 CP949
        let names = [raw(Array("readme.txt".utf8)), raw(cp949Bytes("폴더/문서.hwp")), raw(Array("a/b.txt".utf8))]
        let enc = FilenameCodec.chooseEncoding(names)
        Harness.expectEqual(enc, .cp949, "혼합 판별")
        Harness.expectEqual(names.map { FilenameCodec.decode($0, using: enc) },
                            ["readme.txt", "폴더/문서.hwp", "a/b.txt"], "혼합 디코드")

        // 디코드 결과는 NFC
        let d = FilenameCodec.decode(raw(Array(nfd.utf8)), using: .utf8)
        Harness.expectEqual(Array(d.unicodeScalars), Array(nfc.unicodeScalars), "디코드 NFC")

        // 둘 다 아닌 바이트
        let junk = raw([0xFF, 0xFE, 0x80])
        Harness.expectEqual(FilenameCodec.chooseEncoding([junk]), .cp437, "CP437 대체")
        Harness.expect(!FilenameCodec.decode(junk, using: .cp437).isEmpty, "CP437 디코드는 비어 있지 않음")

        // 0x7075 유니코드 경로
        let bytes = cp949Bytes("원래.txt")
        let goodCRC = CRC32.checksum(Data(bytes))
        Harness.expectEqual(FilenameCodec.decode(raw(bytes, up: (goodCRC, "유니코드.txt")), using: .cp949),
                            "유니코드.txt", "crc 일치 시 0x7075 우선")
        Harness.expectEqual(FilenameCodec.decode(raw(bytes, up: (goodCRC &+ 1, "유니코드.txt")), using: .cp949),
                            "원래.txt", "crc 불일치 시 무시")
    }
}

import Foundation
import MacZipCore

/// WinZip AES(AE-2) 암호화 zip 쓰기·읽기. macOS 기본 bsdtar(libarchive)와 양방향 교차 검증한다.
func aesChecks() {
    Harness.suite("AES") {
        try withTempDir { dir in
            let fm = FileManager.default
            let src = dir.appendingPathComponent("src")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            let files: [(String, Data)] = [
                ("한글 문서.txt", Data("안녕하세요 AES\n".utf8)),
                ("big.bin", Data((0..<5_000_000).map { _ in UInt8.random(in: 0...255) })),
                ("rep.txt", Data(String(repeating: "반복 데이터 ", count: 200_000).utf8)),
                ("empty.txt", Data()),
            ]
            for (name, data) in files { try data.write(to: src.appendingPathComponent(name)) }

            // 1) MacZip이 만든 AES-256 zip → bsdtar로 풀기
            let mine = dir.appendingPathComponent("mine.zip")
            let w = try ZipWriter(destination: mine)
            for (name, _) in files {
                try w.addFile(at: src.appendingPathComponent(name), entryName: name, password: "pw1234",
                              encryption: .aes256, isCancelled: { false }, bytesProcessed: { _ in })
            }
            try w.finish()
            let out1 = dir.appendingPathComponent("out1")
            try fm.createDirectory(at: out1, withIntermediateDirectories: true)
            let x = sh("/usr/bin/bsdtar", ["-x", "--passphrase", "pw1234", "-f", mine.path, "-C", out1.path])
            Harness.expectEqual(x.status, 0, "bsdtar가 MacZip AES zip을 풂: \(x.err)")
            for (name, data) in files {
                Harness.expect((try? Data(contentsOf: out1.appendingPathComponent(name))) == data, "bsdtar 결과 내용 일치: \(name)")
            }
            let bad = sh("/usr/bin/bsdtar", ["-x", "--passphrase", "wrong", "-f", mine.path, "-C", out1.path])
            Harness.expect(bad.status != 0, "bsdtar 틀린 비밀번호는 실패")

            // 형식: 메서드 99, 0x9901 확장 필드(AE-2, 강도 3=256비트), 암호화 플래그, CRC 0
            let meta = py("""
            import sys, zipfile
            for i in zipfile.ZipFile(sys.argv[1]).infolist():
                e = i.extra; p = e.find(b'\\x01\\x99')
                print(i.compress_type, i.flag_bits & 1, i.CRC, e[p+4:p+6].hex(), e[p+6:p+8].decode(), e[p+8])
            """, [mine.path])
            let rows = meta.out.split(separator: "\n").map(String.init)
            Harness.expectEqual(rows.count, files.count, "항목 수 \(meta.err)")
            Harness.expect(rows.allSatisfy { $0 == "99 1 0 0200 AE 3" }, "AES 메타데이터: \(rows)")

            // 2) bsdtar가 만든 AES-256·AES-128 zip → MacZip으로 풀기
            for strength in ["aes256", "aes128"] {
                let theirs = dir.appendingPathComponent("\(strength).zip")
                let c = sh("/usr/bin/bsdtar", ["-c", "--format", "zip", "--options", "zip:encryption=\(strength)",
                                              "--passphrase", "pw1234", "-f", theirs.path, "-C", src.path] + files.map(\.0))
                Harness.expectEqual(c.status, 0, "bsdtar \(strength) 생성 \(c.err)")
                let r = try ZipReader(url: theirs)
                for e in r.entries {
                    let dest = dir.appendingPathComponent("\(strength)-\(UUID().uuidString)")
                    try r.extract(e, to: dest, password: "pw1234", isCancelled: { false }, bytesProcessed: { _ in })
                    let expected = files.first { $0.0 == e.name }?.1
                    Harness.expect((try? Data(contentsOf: dest)) == expected, "MacZip이 bsdtar \(strength) zip을 풂: \(e.name)")
                }
                let wrongDest = dir.appendingPathComponent("wrong-\(strength)")
                Harness.expectThrows({ try r.extract(r.entries[1], to: wrongDest, password: "wrong", isCancelled: { false }, bytesProcessed: { _ in }) },
                                     matching: { ($0 as? ZipError) == .wrongPassword }, "\(strength) 틀린 비밀번호")
                Harness.expect(!fm.fileExists(atPath: wrongDest.path), "\(strength) 틀린 비밀번호 후 파일 없음")
            }

            // 3) Archiver 왕복 (AES-256)
            let c = try Archiver.compress(inputs: [src], password: "pw1234", encryption: .aes256, progress: { _ in }, isCancelled: { false })
            Harness.expect(try Archiver.inspect(zip: c.output).isEncrypted, "inspect: AES zip은 비밀번호 필요")
            Harness.expectThrows({ _ = try Archiver.extract(zip: c.output, password: "wrong", progress: { _ in }, isCancelled: { false }) },
                                 matching: { ($0 as? ZipError) == .wrongPassword }, "Archiver 틀린 비밀번호")
            let back = try Archiver.extract(zip: c.output, password: "pw1234", progress: { _ in }, isCancelled: { false })
            Harness.expect(back.failures.isEmpty, "Archiver 해제 실패 없음: \(back.failures.map(\.name))")
            Harness.expectEqual(sh("/usr/bin/diff", ["-r", src.path, back.outputFolder.appendingPathComponent("src").path]).status, 0, "AES 왕복 diff")

            // 4) 암호문이 손상된 항목만 실패, 나머지는 풀림
            var damaged = try Data(contentsOf: mine)
            let nameLen = Int(damaged[26]) | Int(damaged[27]) << 8, extraLen = Int(damaged[28]) | Int(damaged[29]) << 8
            let cipherStart = 30 + nameLen + extraLen + 16 + 2   // 솔트 16 + 검증값 2 뒤
            damaged[cipherStart + 3] ^= 0xFF
            let damagedURL = dir.appendingPathComponent("damaged.zip")
            try damaged.write(to: damagedURL)
            let d = try Archiver.extract(zip: damagedURL, password: "pw1234", progress: { _ in }, isCancelled: { false })
            Harness.expectEqual(d.failures.map(\.name), [files[0].0], "손상된 AES 항목만 실패")
            Harness.expectEqual(d.extractedCount, files.count - 1, "나머지 AES 항목은 풀림")
        }
    }
}

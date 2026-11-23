import Foundation
import MaczipCore

/// 최종 리뷰 지적 사항 재현 검사.
func reviewFixChecks() {
    Harness.suite("ReviewFix") {
        try withTempDir { dir in
            let fm = FileManager.default
            func rawZip(_ entries: [RawZipEntry]) throws -> URL {
                let u = dir.appendingPathComponent("r-\(UUID().uuidString).zip")
                try buildRawZip(entries).write(to: u)
                return u
            }
            func extract(_ zip: URL, _ pw: String? = nil) throws -> ExtractResult {
                try Archiver.extract(zip: zip, password: pw, progress: { _ in }, isCancelled: { false })
            }
            func failed(_ r: ExtractResult) -> [String] { r.failures.map(\.name).sorted() }
            let blob = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

            // Important 1: 선언 크기보다 많이/적게 나오면 해당 항목 실패, 파일 없음
            let bomb = try extract(rawZip([
                RawZipEntry(nameBytes: Array("bomb.txt".utf8), data: blob, usizeOverride: 10),
                RawZipEntry(nameBytes: Array("short.txt".utf8), data: blob, usizeOverride: 100_000),
                RawZipEntry(nameBytes: Array("ok.txt".utf8), data: Data("ok".utf8)),
            ]))
            Harness.expectEqual(failed(bomb), ["bomb.txt", "short.txt"], "크기 불일치 항목 실패")
            Harness.expectEqual((try? fm.contentsOfDirectory(atPath: bomb.outputFolder.path))?.sorted(), ["ok.txt"], "크기 불일치 파일 없음")

            // Important 2: 한 항목의 파일시스템 충돌은 그 항목만 실패
            let longName = String(repeating: "가", count: 260) + ".txt"   // APFS 한도 255자 초과
            let clash = try extract(rawZip([
                RawZipEntry(nameBytes: Array("A".utf8), data: Data("1".utf8)),
                RawZipEntry(nameBytes: Array("a/".utf8)),
                RawZipEntry(nameBytes: Array("a/x.txt".utf8), data: Data("2".utf8)),
                RawZipEntry(nameBytes: cp949Bytes(longName), data: Data("3".utf8)),
                RawZipEntry(nameBytes: Array("b.txt".utf8), data: Data("4".utf8)),
            ]))
            Harness.expect(fm.fileExists(atPath: clash.outputFolder.appendingPathComponent("b.txt").path), "무관한 항목은 풀림")
            Harness.expect(failed(clash).contains("a/x.txt"), "충돌 항목 실패 기록: \(failed(clash))")
            Harness.expect(failed(clash).contains(longName), "너무 긴 이름 실패 기록")

            // Important 3: 손상된 암호화 항목은 그 항목만 실패, 나머지는 풀림
            let damaged = try extract(rawZip([
                RawZipEntry(nameBytes: Array("s1.txt".utf8), data: blob, passwordBytes: Array("right".utf8), corruptPayloadAt: 500),
                RawZipEntry(nameBytes: Array("s2.txt".utf8), data: Data("fine".utf8), passwordBytes: Array("right".utf8)),
            ]), "right")
            Harness.expectEqual(failed(damaged), ["s1.txt"], "손상 항목만 실패")
            Harness.expect(fm.fileExists(atPath: damaged.outputFolder.appendingPathComponent("s2.txt").path), "정상 암호 항목은 풀림")
            Harness.expectThrows({ _ = try extract(rawZip([
                RawZipEntry(nameBytes: Array("s.txt".utf8), data: blob, passwordBytes: Array("right".utf8)),
                RawZipEntry(nameBytes: Array("t.txt".utf8), data: blob, passwordBytes: Array("right".utf8)),
            ]), "wrong") }, matching: { ($0 as? ZipError) == .wrongPassword }, "틀린 비밀번호는 여전히 wrongPassword")

            // Important 4: 읽을 수 없는 하위 폴더가 있으면 조용히 빠뜨리지 않고 실패
            let src = dir.appendingPathComponent("src")
            try fm.createDirectory(at: src.appendingPathComponent("locked"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: src.appendingPathComponent("locked/b.txt"))
            try Data("y".utf8).write(to: src.appendingPathComponent("a.txt"))
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.appendingPathComponent("locked").path)
            Harness.expectThrows({ _ = try Archiver.compress(inputs: [src], password: nil, progress: { _ in }, isCancelled: { false }) },
                                 matching: { if case .io? = $0 as? ZipError { return true }; return false }, "읽을 수 없는 하위 폴더")
            Harness.expect(!fm.fileExists(atPath: dir.appendingPathComponent("src.zip").path), "반쪽 zip 없음")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("locked").path)

            // Important 5: 실패 사유를 사용자 문구로, AES 전용 zip은 비밀번호를 묻지 않음
            let aesZip = try rawZip([RawZipEntry(nameBytes: Array("aes.txt".utf8), flags: 0x1, data: Data("x".utf8), method: 99)])
            Harness.expectEqual(try Archiver.inspect(zip: aesZip).isEncrypted, false, "AES 전용은 비밀번호 대상 아님")
            let aes = try extract(aesZip)
            Harness.expect(aes.failureSummary?.contains("AES 암호화는 지원하지 않습니다") == true, "AES 사유 표시: \(aes.failureSummary ?? "nil")")
            let lzma = try extract(rawZip([RawZipEntry(nameBytes: Array("l.txt".utf8), data: Data("x".utf8), method: 14)]))
            Harness.expect(lzma.failureSummary?.contains("지원하지 않는 압축 방식") == true, "압축 방식 사유 표시")
            Harness.expectEqual(ZipError.wrongPassword.userMessage, "비밀번호가 맞지 않습니다.", "오류 문구")

            // (재분류) 비트 3이 켜져 있어도 CRC 상위 바이트를 검사 바이트로 쓴 zip을 연다
            let deviant = try rawZip([RawZipEntry(nameBytes: Array("d.txt".utf8), flags: 0x8, data: blob, passwordBytes: Array("pw".utf8))])
            Harness.expectEqual(try extract(deviant, "pw").extractedCount, 1, "검사 바이트 두 방식 모두 허용")
        }
    }
}

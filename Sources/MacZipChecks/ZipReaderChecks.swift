import Foundation
import MacZipCore

private func isErr(_ e: ZipError) -> (Error) -> Bool { { ($0 as? ZipError) == e } }
private func isCorrupt(_ e: Error) -> Bool { if case .corrupt? = e as? ZipError { return true }; return false }

/// zip 하나를 읽어 모든 파일 항목을 dir/out에 풀고 (이름 → 내용) 을 돌려준다.
private func readAll(_ zip: URL, _ dir: URL, password: String? = nil) throws -> [String: Data] {
    let r = try ZipReader(url: zip)
    var result: [String: Data] = [:]
    for (i, e) in r.entries.enumerated() where !e.isDirectory {
        let dest = dir.appendingPathComponent("out-\(UUID().uuidString)-\(i)")
        try r.extract(e, to: dest, password: password, isCancelled: { false }, bytesProcessed: { _ in })
        result[e.name] = try Data(contentsOf: dest)
    }
    return result
}

func zipReaderChecks() {
    Harness.suite("ZipReader") {
        try withTempDir { dir in
            let hello = Data("안녕하세요 MacZip\n".utf8)
            let big = Data(String(repeating: "압축 가능한 반복 데이터 ", count: 50_000).utf8)
            try hello.write(to: dir.appendingPathComponent("한글 문서.txt"))
            try big.write(to: dir.appendingPathComponent("big.txt"))

            // /usr/bin/zip 평문·암호, 표준입력 스트리밍(데이터 디스크립터)
            sh("/usr/bin/zip", ["-q", "plain.zip", "한글 문서.txt", "big.txt"], cwd: dir)
            sh("/usr/bin/zip", ["-q", "-P", "pw", "enc.zip", "한글 문서.txt", "big.txt"], cwd: dir)
            let streamed = sh("/usr/bin/zip", ["-q", "-", "big.txt"], cwd: dir).out
            try streamed.write(to: dir.appendingPathComponent("stream.zip"))

            let expected = ["한글 문서.txt": hello, "big.txt": big]
            Harness.expect(try readAll(dir.appendingPathComponent("plain.zip"), dir) == expected, "zip 평문")
            Harness.expect(try readAll(dir.appendingPathComponent("enc.zip"), dir, password: "pw") == expected, "zip -P 암호")
            Harness.expect(try readAll(dir.appendingPathComponent("stream.zip"), dir) == ["big.txt": big], "데이터 디스크립터")

            // 인코딩 판별
            func zipOf(_ entries: [RawZipEntry]) throws -> URL {
                let u = dir.appendingPathComponent("raw-\(UUID().uuidString).zip")
                try buildRawZip(entries).write(to: u)
                return u
            }
            let nfd = "한글 문서.txt".decomposedStringWithCanonicalMapping
            let rNFD = try ZipReader(url: zipOf([RawZipEntry(nameBytes: Array(nfd.utf8), data: hello)]))
            Harness.expectEqual(rNFD.nameEncoding, .utf8, "NFD 판별")
            Harness.expectEqual(rNFD.entries.first?.name, "한글 문서.txt", "NFD → NFC 이름")

            let rCP = try ZipReader(url: zipOf([
                RawZipEntry(nameBytes: Array("readme.txt".utf8), data: hello),
                RawZipEntry(nameBytes: cp949Bytes("한글 문서.txt"), data: hello),
            ]))
            Harness.expectEqual(rCP.nameEncoding, .cp949, "CP949 판별")
            Harness.expectEqual(rCP.entries.map(\.name), ["readme.txt", "한글 문서.txt"], "CP949 이름")

            let rFlag = try ZipReader(url: zipOf([RawZipEntry(nameBytes: Array("플래그.txt".utf8), flags: 0x800, data: hello)]))
            Harness.expectEqual(rFlag.entries.first?.name, "플래그.txt", "UTF-8 플래그 이름")

            let raw = cp949Bytes("원래.txt")
            let rUP = try ZipReader(url: zipOf([RawZipEntry(nameBytes: raw, data: hello,
                                                            extra: unicodePathExtra(rawName: raw, name: "유니코드.txt"))]))
            Harness.expectEqual(rUP.entries.first?.name, "유니코드.txt", "0x7075 우선")

            // 오류
            let encRaw = try zipOf([RawZipEntry(nameBytes: Array("s.txt".utf8), data: hello, passwordBytes: Array("right".utf8))])
            let encReader = try ZipReader(url: encRaw)
            let encEntry = encReader.entries[0]
            Harness.expect(encEntry.isEncrypted, "암호화 표시")
            let out1 = dir.appendingPathComponent("o1")
            Harness.expectThrows({ try encReader.extract(encEntry, to: out1, password: nil, isCancelled: { false }, bytesProcessed: { _ in }) },
                                 matching: isErr(.passwordRequired), "비밀번호 필요")
            Harness.expectThrows({ try encReader.extract(encEntry, to: out1, password: "wrong", isCancelled: { false }, bytesProcessed: { _ in }) },
                                 matching: isErr(.wrongPassword), "틀린 비밀번호")
            Harness.expect(!FileManager.default.fileExists(atPath: out1.path), "틀린 비밀번호 후 파일 없음")

            let badCRC = try ZipReader(url: zipOf([RawZipEntry(nameBytes: Array("bad.txt".utf8), data: hello, crcOverride: 0xDEAD_BEEF)]))
            let out2 = dir.appendingPathComponent("o2")
            Harness.expectThrows({ try badCRC.extract(badCRC.entries[0], to: out2, password: nil, isCancelled: { false }, bytesProcessed: { _ in }) },
                                 matching: isErr(.crcMismatch(entry: "bad.txt")), "CRC 불일치")
            Harness.expect(!FileManager.default.fileExists(atPath: out2.path), "CRC 불일치 후 파일 없음")

            let junk = dir.appendingPathComponent("junk.zip")
            try Data((0..<4096).map { _ in UInt8.random(in: 0...0x4F) }).write(to: junk)
            Harness.expectThrows({ _ = try ZipReader(url: junk) }, matching: isErr(.notAZip), "zip 아님")

            var cut = try Data(contentsOf: dir.appendingPathComponent("plain.zip"))
            cut.removeSubrange(200..<1200)
            let cutURL = dir.appendingPathComponent("cut.zip")
            try cut.write(to: cutURL)
            Harness.expectThrows({ _ = try readAll(cutURL, dir) }, matching: isCorrupt, "중간이 잘린 zip")

            let aes = try ZipReader(url: zipOf([RawZipEntry(nameBytes: Array("aes.txt".utf8), flags: 0x1, data: hello, method: 99)]))
            Harness.expectThrows({ try aes.extract(aes.entries[0], to: dir.appendingPathComponent("o3"), password: "x", isCancelled: { false }, bytesProcessed: { _ in }) },
                                 matching: isErr(.unsupportedAES(entry: "aes.txt")), "AES 미지원")

            // (Review Focus 1) CP949·UTF-8 비밀번호 바이트 모두 같은 문자열로 열림
            for (label, bytes) in [("CP949", cp949Bytes("한글비번")), ("UTF-8", Array("한글비번".utf8))] {
                let u = try zipOf([RawZipEntry(nameBytes: Array("k.txt".utf8), data: hello, passwordBytes: bytes)])
                Harness.expect((try? readAll(u, dir, password: "한글비번")) == ["k.txt": hello], "한글 비밀번호 \(label)")
            }

            // (Review Focus 5) 빈 zip, 빈 디렉터리 항목
            let emptyZip = try zipOf([])
            Harness.expect((try? ZipReader(url: emptyZip))?.entries.isEmpty == true, "빈 zip")
            let dirZip = try ZipReader(url: zipOf([RawZipEntry(nameBytes: Array("빈폴더/".utf8), unixMode: 0o040755)]))
            Harness.expect(dirZip.entries.first?.isDirectory == true, "디렉터리 항목")

            // 권한·시간 복원, 심볼릭 링크 표시
            let exe = try ZipReader(url: zipOf([
                RawZipEntry(nameBytes: Array("run.sh".utf8), data: hello, unixMode: 0o100755),
                RawZipEntry(nameBytes: Array("link".utf8), data: Data("run.sh".utf8), unixMode: 0o120777),
            ]))
            let out4 = dir.appendingPathComponent("run.sh")
            try exe.extract(exe.entries[0], to: out4, password: nil, isCancelled: { false }, bytesProcessed: { _ in })
            let attrs = try FileManager.default.attributesOfItem(atPath: out4.path)
            Harness.expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755, "실행 비트 복원")
            let year = Calendar.current.component(.year, from: attrs[.modificationDate] as! Date)
            Harness.expectEqual(year, 2025, "수정 시간 복원")
            Harness.expect(exe.entries[1].isSymlink, "심볼릭 링크 표시")

            // 큰 파일 메모리 (--big 에서만)
            if Harness.flags.contains("--big") {
                sh("/usr/sbin/mkfile", ["-n", "400m", "zeros.bin"], cwd: dir)
                sh("/usr/bin/zip", ["-q", "-0", "bigzip.zip", "zeros.bin"], cwd: dir)
                let before = maxRSS()
                let r = try ZipReader(url: dir.appendingPathComponent("bigzip.zip"))
                try r.extract(r.entries[0], to: dir.appendingPathComponent("zeros.out"), password: nil, isCancelled: { false }, bytesProcessed: { _ in })
                let grew = maxRSS() - before
                Harness.expect(grew < 100 * 1024 * 1024, "400MB 해제 시 메모리 증가 \(grew / 1024 / 1024)MB < 100MB")
            }
        }
    }
}

func maxRSS() -> Int {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Int(u.ru_maxrss)
}

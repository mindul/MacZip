import Foundation
import MaczipCore

private let fm = FileManager.default
private func isErr(_ e: ZipError) -> (Error) -> Bool { { ($0 as? ZipError) == e } }
private func isIO(_ e: Error) -> Bool { if case .io? = e as? ZipError { return true }; return false }
private func compress(_ inputs: [URL], _ pw: String? = nil, cancel: @escaping () -> Bool = { false }) throws -> CompressResult {
    try Archiver.compress(inputs: inputs, password: pw, progress: { _ in }, isCancelled: cancel)
}
private func extract(_ zip: URL, _ pw: String? = nil, cancel: @escaping () -> Bool = { false }) throws -> ExtractResult {
    try Archiver.extract(zip: zip, password: pw, progress: { _ in }, isCancelled: cancel)
}
private func children(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
private func noTemp(_ dir: URL) -> Bool { !children(dir).contains { $0.contains("maczip-tmp") } }
private func write(_ s: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(s.utf8).write(to: url)
}

func archiverChecks() {
    Harness.suite("Archiver") {
        try withTempDir { dir in
            // 왕복
            let src = dir.appendingPathComponent("자료")
            try write("문서 내용", src.appendingPathComponent("하위/문서.txt"))
            try write("", src.appendingPathComponent("빈 파일.txt"))
            try write("#!/bin/sh\necho hi\n", src.appendingPathComponent("run.sh"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("run.sh").path)
            try fm.createDirectory(at: src.appendingPathComponent("빈 폴더"), withIntermediateDirectories: true)

            for pw in [nil, "pw1234"] as [String?] {
                let c = try compress([src], pw)
                Harness.expectEqual(sh("/usr/bin/unzip", ["-tq"] + (pw.map { ["-P", $0] } ?? []) + [c.output.path]).status, 0, "unzip -t (\(pw ?? "암호 없음"))")
                let names = Set(pyInspect(c.output, password: pw).entries?.map(\.name) ?? [])
                Harness.expectEqual(names, ["자료/", "자료/하위/", "자료/하위/문서.txt", "자료/빈 파일.txt", "자료/run.sh", "자료/빈 폴더/"], "항목 이름")
                let x = try extract(c.output, pw)
                Harness.expect(x.failures.isEmpty, "실패 없음")
                Harness.expectEqual(sh("/usr/bin/diff", ["-r", src.path, x.outputFolder.appendingPathComponent("자료").path]).status, 0, "diff -r 왕복")
                let mode = (try fm.attributesOfItem(atPath: x.outputFolder.appendingPathComponent("자료/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue
                Harness.expectEqual(mode, 0o755, "실행 비트 왕복")
            }
            Harness.expectEqual(children(dir).filter { $0.hasSuffix(".zip") }, ["자료 2.zip", "자료.zip"], "같은 이름 zip 번호")

            // 이름 규칙
            let names = dir.appendingPathComponent("names")
            try write("x", names.appendingPathComponent("보고서.hwp"))
            try write("y", names.appendingPathComponent("b.txt"))
            Harness.expectEqual(try compress([names.appendingPathComponent("보고서.hwp")]).output.lastPathComponent, "보고서.hwp.zip", "단일 파일 이름")
            let two = [names.appendingPathComponent("보고서.hwp"), names.appendingPathComponent("b.txt")]
            Harness.expectEqual(try compress(two).output.lastPathComponent, "보관.zip", "여러 항목 이름")
            Harness.expectEqual(try compress(two).output.lastPathComponent, "보관 2.zip", "여러 항목 번호")

            // 제외 항목과 심볼릭 링크
            let junk = dir.appendingPathComponent("junk")
            try write("keep", junk.appendingPathComponent("keep.txt"))
            try write("x", junk.appendingPathComponent(".DS_Store"))
            try write("x", junk.appendingPathComponent("._keep.txt"))
            try write("x", junk.appendingPathComponent("__MACOSX/a.txt"))
            try fm.createSymbolicLink(atPath: junk.appendingPathComponent("link").path, withDestinationPath: "keep.txt")
            let cj = try compress([junk])
            Harness.expectEqual(pyInspect(cj.output).entries?.map(\.name) ?? [], ["junk/", "junk/keep.txt"], "제외 항목")
            Harness.expectEqual(cj.skippedSymlinks, 1, "심볼릭 링크 건너뜀")

            // (Review Focus 2) 출력이 입력 폴더 안에 생김
            let a = dir.appendingPathComponent("A")
            try write("x", a.appendingPathComponent("x.txt"))
            let ca = try compress([a.appendingPathComponent("x.txt"), a])
            Harness.expectEqual(ca.output.deletingLastPathComponent().lastPathComponent, "A", "출력 위치는 A 안")
            Harness.expectEqual(Set(pyInspect(ca.output).entries?.map(\.name) ?? []), ["x.txt", "A/", "A/x.txt"], "자기 자신 미포함")

            // 루트 이름 겹침
            let d1 = dir.appendingPathComponent("d1"), d2 = dir.appendingPathComponent("d2")
            try write("1", d1.appendingPathComponent("same.txt")); try write("2", d2.appendingPathComponent("SAME.txt"))
            let cs = try compress([d1.appendingPathComponent("same.txt"), d2.appendingPathComponent("SAME.txt")])
            Harness.expectEqual(pyInspect(cs.output).entries?.map(\.name) ?? [], ["same.txt", "SAME 2.txt"], "루트 이름 겹침")

            func rawZip(_ entries: [RawZipEntry], _ name: String) throws -> URL {
                let u = dir.appendingPathComponent(name)
                try buildRawZip(entries).write(to: u)
                return u
            }
            func e(_ n: String, _ s: String, crc: UInt32? = nil, pw: String? = nil) -> RawZipEntry {
                RawZipEntry(nameBytes: Array(n.utf8), data: Data(s.utf8), crcOverride: crc, passwordBytes: pw.map { Array($0.utf8) })
            }

            // (Review Focus 3) 중복 이름, 대소문자만 다른 이름
            let dup = try extract(rawZip([e("a.txt", "1"), e("a.txt", "2"), e("B.txt", "3"), e("b.txt", "4")], "dup.zip"))
            let files = children(dup.outputFolder)
            Harness.expectEqual(files.count, 4, "중복 이름 4개 모두 남음: \(files)")
            let contents = Set(files.compactMap { try? String(contentsOf: dup.outputFolder.appendingPathComponent($0), encoding: .utf8) })
            Harness.expectEqual(contents, ["1", "2", "3", "4"], "내용이 섞이지 않음")

            // (Review Focus 4) 쓸 수 없는 위치
            let ro = dir.appendingPathComponent("ro")
            try write("x", ro.appendingPathComponent("f.txt"))
            let roZip = try compress([ro.appendingPathComponent("f.txt")]).output
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
            Harness.expectThrows({ _ = try compress([ro.appendingPathComponent("f.txt")]) }, matching: isIO, "읽기 전용 폴더 압축")
            Harness.expectEqual(children(ro), ["f.txt", "f.txt.zip"], "반쪽 zip 없음")
            Harness.expectThrows({ _ = try extract(roZip) }, matching: isIO, "읽기 전용 폴더 해제")
            Harness.expect(noTemp(ro), "임시 폴더 없음")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path)

            // (Review Focus 5) 빈 폴더, 빈 zip
            let empty = dir.appendingPathComponent("빈")
            try fm.createDirectory(at: empty, withIntermediateDirectories: true)
            let ce = try compress([empty])
            Harness.expectEqual(pyInspect(ce.output).entries?.map(\.name) ?? [], ["빈/"], "빈 폴더 항목")
            let xe = try extract(ce.output)
            Harness.expectEqual(children(xe.outputFolder.appendingPathComponent("빈")), [], "빈 폴더 복원")
            let xz = try extract(rawZip([], "empty.zip"))
            Harness.expectEqual(xz.extractedCount, 0, "빈 zip 해제")
            Harness.expect(children(xz.outputFolder).isEmpty, "빈 출력 폴더")

            // 비밀번호 오류
            let encZip = try rawZip([e("s.txt", "secret", pw: "right")], "enc.zip")
            Harness.expectThrows({ _ = try extract(encZip, "wrong") }, matching: isErr(.wrongPassword), "틀린 비밀번호")
            Harness.expectThrows({ _ = try extract(encZip, nil) }, matching: isErr(.passwordRequired), "비밀번호 필요")
            Harness.expect(!children(dir).contains("enc") && noTemp(dir), "비밀번호 오류 후 아무것도 남지 않음")
            Harness.expectEqual(try extract(encZip, "right").extractedCount, 1, "올바른 비밀번호")

            // 악의적 경로, CRC 오류
            let outside = "/tmp/maczip-evil-\(UUID().uuidString).txt"
            let evil = try extract(rawZip([e("../evil.txt", "x"), e(outside, "x"), e("ok.txt", "ok"),
                                           e("bad.txt", "bad", crc: 0x1234)], "evil.zip"))
            Harness.expect(!fm.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.txt").path), "상위 폴더에 안 씀")
            Harness.expect(!fm.fileExists(atPath: outside), "절대 경로에 안 씀")
            Harness.expectEqual(evil.failures.filter { if case .unsafePath = $0.error { return true }; return false }.count, 2, "unsafePath 2건")
            Harness.expect(evil.failures.contains { $0.error == .crcMismatch(entry: "bad.txt") }, "CRC 실패 기록")
            Harness.expectEqual(children(evil.outputFolder), ["ok.txt"], "정상 항목만 남음")

            // 취소
            Harness.expectThrows({ _ = try compress([src], cancel: { true }) }, matching: isErr(.cancelled), "압축 취소")
            Harness.expect(!children(dir).contains("자료 3.zip"), "취소 후 zip 없음")
            let before = children(dir)
            Harness.expectThrows({ _ = try extract(dir.appendingPathComponent("자료.zip"), cancel: { true }) },
                                 matching: isErr(.cancelled), "해제 취소")
            Harness.expectEqual(children(dir), before, "취소 후 출력·임시 폴더 없음")

            // DropClassifier
            let zipDir = dir.appendingPathComponent("폴더.zip")
            try fm.createDirectory(at: zipDir, withIntermediateDirectories: true)
            Harness.expect(DropClassifier.mode(for: []) == nil, "빈 드롭")
            Harness.expect(DropClassifier.mode(for: [dir.appendingPathComponent("a.ZIP")]) == .extract, "zip 하나")
            Harness.expect(DropClassifier.mode(for: [zipDir]) == .compress, "zip 이름 폴더")
            Harness.expect(DropClassifier.mode(for: [encZip, src]) == .compress, "여러 항목")
            Harness.expect(DropClassifier.mode(for: [src]) == .compress, "폴더")

            // inspect
            sh("/usr/bin/zip", ["-q", "-P", "pw", "insp.zip", "자료.zip"], cwd: dir)
            let info = try Archiver.inspect(zip: dir.appendingPathComponent("insp.zip"))
            Harness.expect(info.isEncrypted && info.entryCount == 1, "inspect 암호화·개수")
            Harness.expectEqual(info.totalUncompressedBytes,
                                UInt64((try fm.attributesOfItem(atPath: dir.appendingPathComponent("자료.zip").path)[.size] as! NSNumber).intValue), "inspect 크기")
            let cpInfo = try Archiver.inspect(zip: rawZip([RawZipEntry(nameBytes: cp949Bytes("한글.txt"))], "cp.zip"))
            Harness.expectEqual(cpInfo.nameEncoding, .cp949, "inspect 인코딩")
        }
    }
}

import Foundation
import MaczipCore

func zipWriterChecks() {
    Harness.suite("ZipWriter") {
        try withTempDir { dir in
            let hello = Data("안녕하세요\n".utf8)
            let emoji = Data(String(repeating: "🙂 emoji ", count: 1000).utf8)
            let f1 = dir.appendingPathComponent("f1"), f2 = dir.appendingPathComponent("f2")
            try hello.write(to: f1); try emoji.write(to: f2)

            // 평문 zip: 이름은 일부러 NFD로 넘긴다.
            let plainZip = dir.appendingPathComponent("plain.zip")
            let w = try ZipWriter(destination: plainZip)
            try w.addDirectory(entryName: "보고서".decomposedStringWithCanonicalMapping, modified: Date(), unixMode: 0o755)
            try w.addFile(at: f1, entryName: "보고서/한글 파일.txt".decomposedStringWithCanonicalMapping,
                          password: nil, isCancelled: { false }, bytesProcessed: { _ in })
            try w.addFile(at: f2, entryName: "emoji 🙂.txt", password: nil, isCancelled: { false }, bytesProcessed: { _ in })
            try w.finish()

            Harness.expectEqual(sh("/usr/bin/unzip", ["-tq", plainZip.path]).status, 0, "unzip -t 평문")
            let (entries, err) = pyInspect(plainZip)
            Harness.expectEqual(entries?.map(\.name) ?? [], ["보고서/", "보고서/한글 파일.txt", "emoji 🙂.txt"], "이름(NFC) \(err)")
            Harness.expect(entries?.allSatisfy { $0.flag & 0x800 != 0 } ?? false, "UTF-8 플래그")
            Harness.expectEqual(entries?.map(\.sha).dropFirst().map { $0 } ?? [], [sha256Hex(hello), sha256Hex(emoji)], "내용")
            Harness.expectEqual((entries?.first?.mode ?? 0) & 0o777, 0o755, "디렉터리 권한")
            if let names = entries?.map(\.name) {
                Harness.expect(names.allSatisfy { $0 == $0.precomposedStringWithCanonicalMapping }, "모든 이름이 NFC")
            }

            // 암호 zip
            let big = dir.appendingPathComponent("big.bin"), rep = dir.appendingPathComponent("rep.txt")
            let bigData = Data((0..<5_000_000).map { _ in UInt8.random(in: 0...255) })
            let repData = Data(String(repeating: "반복 ", count: 1_000_000).utf8)
            try bigData.write(to: big); try repData.write(to: rep)
            let encZip = dir.appendingPathComponent("enc.zip")
            let we = try ZipWriter(destination: encZip)
            var processed: Int64 = 0
            try we.addFile(at: big, entryName: "큰 파일.bin", password: "pw1234", isCancelled: { false }, bytesProcessed: { processed += $0 })
            try we.addFile(at: rep, entryName: "반복.txt", password: "pw1234", isCancelled: { false }, bytesProcessed: { _ in })
            try we.finish()
            Harness.expectEqual(processed, Int64(bigData.count), "진행 바이트 합계")
            let (encEntries, encErr) = pyInspect(encZip, password: "pw1234")
            Harness.expectEqual(encEntries?.map(\.sha) ?? [], [sha256Hex(bigData), sha256Hex(repData)], "Python 복호화 \(encErr)")
            Harness.expect(encEntries?.allSatisfy { $0.flag & 0x1 != 0 } ?? false, "암호화 플래그")
            Harness.expectEqual(sh("/usr/bin/unzip", ["-tq", "-P", "pw1234", encZip.path]).status, 0, "unzip -P 올바른 비밀번호")
            Harness.expect(sh("/usr/bin/unzip", ["-tq", "-P", "wrong", encZip.path]).status != 0, "unzip -P 틀린 비밀번호는 실패")

            // store 대상: 크기 0, 압축된 확장자
            let empty = dir.appendingPathComponent("empty"), inner = dir.appendingPathComponent("inner.zip")
            try Data().write(to: empty); try emoji.write(to: inner)
            let storeZip = dir.appendingPathComponent("store.zip")
            let ws = try ZipWriter(destination: storeZip)
            try ws.addFile(at: empty, entryName: "빈 파일", password: nil, isCancelled: { false }, bytesProcessed: { _ in })
            try ws.addFile(at: inner, entryName: "안쪽.zip", password: nil, isCancelled: { false }, bytesProcessed: { _ in })
            try ws.addFile(at: f2, entryName: "압축됨.txt", password: nil, isCancelled: { false }, bytesProcessed: { _ in })
            try ws.finish()
            Harness.expectEqual(pyInspect(storeZip).entries?.map(\.method) ?? [], [0, 0, 8], "메서드 선택")
            Harness.expectEqual(sh("/usr/bin/unzip", ["-tq", storeZip.path]).status, 0, "unzip -t store")

            // 취소
            let cancelZip = dir.appendingPathComponent("cancel.zip")
            let wc = try ZipWriter(destination: cancelZip)
            Harness.expectThrows({
                try wc.addFile(at: big, entryName: "x", password: nil, isCancelled: { true }, bytesProcessed: { _ in })
            }, matching: { ($0 as? ZipError) == .cancelled }, "취소")
        }
    }
}

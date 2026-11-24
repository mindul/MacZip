import Foundation
import MacZipCore

private let fm = FileManager.default

private func linkTarget(_ url: URL) -> String? { try? fm.destinationOfSymbolicLink(atPath: url.path) }
private func isLink(_ url: URL) -> Bool {
    ((try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
}
private func children(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
private func linkEntry(_ name: String, _ target: String, password: [UInt8]? = nil) -> RawZipEntry {
    RawZipEntry(nameBytes: Array(name.utf8), data: Data(target.utf8), unixMode: 0o120755, passwordBytes: password)
}
private func fileEntry(_ name: String, _ text: String) -> RawZipEntry {
    RawZipEntry(nameBytes: Array(name.utf8), data: Data(text.utf8), unixMode: 0o100644)
}

/// 심볼릭 링크: 앱 번들처럼 폴더 안을 가리키는 링크는 보존하고, 밖으로 나가는 링크는 막는다.
func symlinkChecks() {
    Harness.suite("Symlink") {
        // 대상 경로 규칙
        let safe = PathSafety.isSafeSymlinkTarget
        Harness.expect(safe("A", ["F.framework", "Versions", "Current"]), "같은 폴더")
        Harness.expect(safe("Versions/Current/F", ["F.framework", "F"]), "아래로")
        Harness.expect(safe("../B/x", ["a", "l"]), "한 단계 위")
        Harness.expect(safe("./A/./b", ["l"]), "점 경로")
        Harness.expect(!safe("../x", ["l"]), "루트 밖으로")
        Harness.expect(!safe("../../x", ["a", "l"]), "두 단계 위로 밖")
        Harness.expect(!safe("/etc/passwd", ["a", "l"]), "절대 경로")
        Harness.expect(!safe("d/..", ["sub", "e"]), "이름 뒤의 ..(링크 이어 붙이기)")
        Harness.expect(!safe("a/../../x", ["s", "l"]), "중간의 ..")
        Harness.expect(!safe("", ["l"]) && !safe(".", ["l"]) && !safe("a\\b", ["l"]) && !safe("a\u{0}b", ["l"]), "빈 값·점·역슬래시·NUL")
        Harness.expect(!safe(String(repeating: "a", count: 1024), ["l"]), "너무 긴 대상")

        try withTempDir { dir in
            // 앱 번들 모양의 폴더: 압축 → 해제 왕복에서 링크가 그대로 살아야 한다.
            let app = dir.appendingPathComponent("Demo.app")
            let fw = app.appendingPathComponent("Contents/Frameworks/F.framework")
            try fm.createDirectory(at: fw.appendingPathComponent("Versions/A/Resources"), withIntermediateDirectories: true)
            try Data("bin".utf8).write(to: fw.appendingPathComponent("Versions/A/F"))
            try Data("res".utf8).write(to: fw.appendingPathComponent("Versions/A/Resources/r.txt"))
            let links: [(String, String)] = [
                ("Contents/Frameworks/F.framework/Versions/Current", "A"),
                ("Contents/Frameworks/F.framework/F", "Versions/Current/F"),
                ("Contents/Frameworks/F.framework/Resources", "Versions/Current/Resources"),
                ("Contents/up", "../Contents/Frameworks"),
            ]
            for (path, target) in links {
                try fm.createSymbolicLink(atPath: app.appendingPathComponent(path).path, withDestinationPath: target)
            }
            try fm.createSymbolicLink(atPath: app.appendingPathComponent("esc").path, withDestinationPath: "../../outside")
            try fm.createSymbolicLink(atPath: app.appendingPathComponent("abs").path, withDestinationPath: "/etc/hosts")

            for (pw, method) in [(nil, EncryptionMethod.zipCrypto), ("pw1234", .zipCrypto), ("pw1234", .aes256)] as [(String?, EncryptionMethod)] {
                let label = pw == nil ? "암호 없음" : "\(method)"
                let c = try Archiver.compress(inputs: [app], password: pw, encryption: method, progress: { _ in }, isCancelled: { false })
                Harness.expectEqual(c.skippedSymlinks, 2, "밖을 가리키는 링크만 건너뜀 (\(label))")
                if pw == nil || method == .zipCrypto {   // macOS unzip은 AES를 풀지 못한다
                    let r = sh("/usr/bin/unzip", ["-tq"] + (pw.map { ["-P", $0] } ?? []) + [c.output.path])
                    Harness.expectEqual(r.status, 0, "unzip -t (\(label)): \(r.err)")
                }
                let x = try Archiver.extract(zip: c.output, password: pw, progress: { _ in }, isCancelled: { false })
                Harness.expect(x.failures.isEmpty, "실패 없음 (\(label)): \(x.failureSummary ?? "")")
                let out = x.outputFolder.appendingPathComponent("Demo.app")
                for (path, target) in links {
                    Harness.expectEqual(linkTarget(out.appendingPathComponent(path)), target, "링크 보존: \(path) (\(label))")
                }
                let viaLink = try? String(contentsOf: out.appendingPathComponent("Contents/Frameworks/F.framework/F"), encoding: .utf8)
                Harness.expectEqual(viaLink, "bin", "링크로 읽기 (\(label))")
                Harness.expect(linkTarget(out.appendingPathComponent("esc")) == nil && linkTarget(out.appendingPathComponent("abs")) == nil,
                               "밖을 가리키는 링크 없음 (\(label))")
                Harness.expect(!children(dir).contains { $0.contains("maczip") }, "임시 폴더 없음 (\(label))")
                Harness.expect(!children(out).contains { $0.contains("maczip-link") }, "링크 임시 파일 없음 (\(label))")
                try fm.removeItem(at: x.outputFolder)
                try fm.removeItem(at: c.output)
            }

            // 악의적인 zip: 어떤 경우에도 결과 폴더 밖을 가리키거나 밖에 쓰지 않아야 한다.
            let evil = dir.appendingPathComponent("evil")
            try fm.createDirectory(at: evil, withIntermediateDirectories: true)
            let zip = evil.appendingPathComponent("evil.zip")
            try buildRawZip([
                linkEntry("abs", "/etc"),
                linkEntry("esc", "../x"),
                fileEntry("sub/keep.txt", "keep"),
                linkEntry("sub/d", ".."),                  // 안전(결과 폴더 자신)
                linkEntry("sub/e", "d/.."),                // 이어 붙이면 밖 → 거부
                linkEntry("l", "sub"),                     // 같은 이름의 폴더가 먼저 생기므로 만들 수 없음
                fileEntry("l/evil.txt", "evil"),
                linkEntry("a", "sub"),                     // 안전
                linkEntry("a/b", "keep.txt"),              // 상위가 링크 → 거부
                linkEntry("long", String(repeating: "x", count: 2000)),
            ]).write(to: zip)
            let x = try Archiver.extract(zip: zip, password: nil, progress: { _ in }, isCancelled: { false })
            let out = x.outputFolder
            Harness.expectEqual(Set(x.failures.map(\.name)), ["abs", "esc", "sub/e", "l", "a/b", "long"], "거부한 링크")
            Harness.expect(x.failures.allSatisfy { if case .unsafePath = $0.error { return true }; return false }, "거부 사유는 안전하지 않은 경로")
            Harness.expectEqual(linkTarget(out.appendingPathComponent("sub/d")), "..", "안전한 링크는 만듦")
            Harness.expectEqual(linkTarget(out.appendingPathComponent("a")), "sub", "안전한 링크는 만듦(a)")
            Harness.expect(!isLink(out.appendingPathComponent("l")), "l은 실제 폴더")
            Harness.expect(fm.fileExists(atPath: out.appendingPathComponent("l/evil.txt").path), "l 안의 파일은 결과 폴더 안에")
            Harness.expect(!fm.fileExists(atPath: out.appendingPathComponent("sub/b").path), "링크를 거쳐 쓰지 않음")
            Harness.expectEqual(children(evil), ["evil", "evil.zip"], "결과 폴더 밖에 아무것도 없음")
            Harness.expect(!fm.fileExists(atPath: dir.appendingPathComponent("x").path), "상위 폴더에 아무것도 없음")

            // 암호 걸린 링크: 틀린 비밀번호면 링크를 만들지 않는다.
            let encZip = evil.appendingPathComponent("enc.zip")
            try buildRawZip([linkEntry("l", "target", password: Array("right".utf8))]).write(to: encZip)
            Harness.expectThrows({ _ = try Archiver.extract(zip: encZip, password: "wrong", progress: { _ in }, isCancelled: { false }) },
                                 matching: { ($0 as? ZipError) == .wrongPassword }, "암호 링크: 틀린 비밀번호")
            let ok = try Archiver.extract(zip: encZip, password: "right", progress: { _ in }, isCancelled: { false })
            Harness.expectEqual(linkTarget(ok.outputFolder.appendingPathComponent("l")), "target", "암호 링크: 맞는 비밀번호")
        }
    }
}

import Foundation
import MaczipCore

func pathChecks() {
    Harness.suite("PathSafety") {
        Harness.expectEqual(PathSafety.safeComponents("a/b.txt"), ["a", "b.txt"], "일반")
        Harness.expectEqual(PathSafety.safeComponents("a\\b.txt"), ["a", "b.txt"], "역슬래시")
        Harness.expectEqual(PathSafety.safeComponents("./a//b"), ["a", "b"], "점·빈 조각")
        Harness.expectEqual(PathSafety.safeComponents("폴더/"), ["폴더"], "디렉터리 이름")
        for bad in ["../x", "a/../../x", "a/..", "/etc/passwd", "C:/x", "C:\\x", "c:x", "a\u{0}b", "", "/", "./"] {
            Harness.expect(PathSafety.safeComponents(bad) == nil, "위험 경로 거부: \(bad.debugDescription)")
        }
    }
    Harness.suite("UniqueName") {
        let base = URL(fileURLWithPath: "/tmp/x")
        func taken(_ names: Set<String>) -> (URL) -> Bool { { names.contains($0.lastPathComponent.lowercased()) } }
        Harness.expectEqual(UniqueName.url(for: base.appendingPathComponent("a.txt"), exists: taken([])).lastPathComponent,
                            "a.txt", "비어 있으면 그대로")
        Harness.expectEqual(UniqueName.url(for: base.appendingPathComponent("a.txt"),
                                           exists: taken(["a.txt", "a 2.txt"])).lastPathComponent, "a 3.txt", "번호")
        Harness.expectEqual(UniqueName.url(for: base.appendingPathComponent("보관"),
                                           exists: taken(["보관"])).lastPathComponent, "보관 2", "확장자 없음")
        Harness.expectEqual(UniqueName.url(for: base.appendingPathComponent("B.TXT"),
                                           exists: taken(["b.txt"])).lastPathComponent, "B 2.TXT", "대소문자 무시 시뮬레이션")
        Harness.expectEqual(UniqueName.url(for: base.appendingPathComponent("a.tar.gz"),
                                           exists: taken(["a.tar.gz"])).lastPathComponent, "a.tar 2.gz", "마지막 확장자 앞")
    }
}

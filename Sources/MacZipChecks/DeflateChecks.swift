import Foundation
import MacZipCore

private func chunks(_ d: Data, _ size: Int) -> [Data] {
    stride(from: 0, to: d.count, by: size).map { d.subdata(in: $0..<min($0 + size, d.count)) }
}

func deflateRoundTrip(_ plain: Data) throws -> (compressed: Data, restored: Data, finished: Bool) {
    let def = RawDeflater()
    var compressed = Data()
    for c in chunks(plain, 7_001) { try def.write(c) { compressed.append($0) } }
    try def.finish { compressed.append($0) }
    let inf = RawInflater()
    var restored = Data()
    for c in chunks(compressed, 4_099) { try inf.write(c) { restored.append($0) } }
    return (compressed, restored, inf.isFinished)
}

func deflateChecks() {
    Harness.suite("Deflate") {
        let random = Data((0..<5_000_000).map { _ in UInt8.random(in: 0...255) })
        let repeated = Data(String(repeating: "한글 반복 문자열 MacZip ", count: 200_000).utf8)
        for (label, plain) in [("빈", Data()), ("1바이트", Data([42])), ("난수 5MB", random), ("반복", repeated)] {
            let r = try deflateRoundTrip(plain)
            Harness.expect(r.restored == plain, "\(label) 왕복")
            Harness.expect(r.finished, "\(label) 스트림 끝 인식")
        }
        let r = try deflateRoundTrip(repeated)
        Harness.expect(r.compressed.count < repeated.count / 10, "반복 데이터는 잘 압축됨")

        // 교차 검증: Python zlib raw inflate
        let p = py("import sys, zlib, hashlib; sys.stdout.write(hashlib.sha256(zlib.decompress(sys.stdin.buffer.read(), -15)).hexdigest())",
                   [], input: r.compressed)
        let expected = sh("/usr/bin/shasum", ["-a", "256"], input: repeated).out
        Harness.expectEqual(p.out, String(String(decoding: expected, as: UTF8.self).prefix(64)), "Python 복원 \(p.err)")

        // 손상된 입력
        var broken = r.compressed
        for i in 0..<10 { broken[i] ^= 0xFF }
        Harness.expectThrows({
            let inf = RawInflater()
            try inf.write(broken) { _ in }
        }, matching: { ($0 as? ZipError).map { if case .corrupt = $0 { return true } else { return false } } ?? false },
           "손상된 입력은 corrupt")
    }
}

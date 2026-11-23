import Foundation

/// Python zipfile로 zip을 읽어 항목 정보를 돌려준다(교차 검증용).
struct PyEntry: Decodable, Equatable {
    let name: String
    let flag: Int
    let method: Int
    let mode: Int
    let sha: String
}

func pyInspect(_ zip: URL, password: String? = nil) -> (entries: [PyEntry]?, err: String) {
    let code = """
    import sys, json, zipfile, hashlib
    z = zipfile.ZipFile(sys.argv[1])
    pw = sys.argv[2].encode() if len(sys.argv) > 2 else None
    out = []
    for i in z.infolist():
        data = b'' if i.is_dir() else z.read(i, pwd=pw)
        out.append(dict(name=i.filename, flag=i.flag_bits, method=i.compress_type,
                        mode=i.external_attr >> 16, sha=hashlib.sha256(data).hexdigest()))
    print(json.dumps(out))
    """
    let r = py(code, [zip.path] + (password.map { [$0] } ?? []))
    let entries = try? JSONDecoder().decode([PyEntry].self, from: Data(r.out.utf8))
    return (entries, r.err)
}

func sha256Hex(_ d: Data) -> String {
    String(String(decoding: sh("/usr/bin/shasum", ["-a", "256"], input: d).out, as: UTF8.self).prefix(64))
}

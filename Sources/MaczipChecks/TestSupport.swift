import Foundation

/// 임시 폴더를 만들어 body에 넘기고, 끝나면 지운다.
func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("maczip-checks-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        // 읽기 전용으로 바꾼 하위 폴더가 있어도 지울 수 있게 권한을 되돌린다.
        _ = sh("/bin/chmod", ["-R", "u+rwx", dir.path])
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

/// 외부 명령 실행. 표준 출력은 Data, 표준 오류는 문자열.
@discardableResult
func sh(_ launchPath: String, _ args: [String], input: Data? = nil,
        cwd: URL? = nil) -> (status: Int32, out: Data, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = inPipe
    do { try p.run() } catch { return (-1, Data(), "\(error)") }
    // 큰 출력에서 파이프가 막히지 않도록 별도 스레드에서 읽는다.
    var out = Data(), err = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    if let input { inPipe.fileHandleForWriting.write(input) }
    try? inPipe.fileHandleForWriting.close()
    p.waitUntilExit()
    group.wait()
    return (p.terminationStatus, out, String(decoding: err, as: UTF8.self))
}

/// `python3 -I -c code args...` 실행.
@discardableResult
func py(_ code: String, _ args: [String], input: Data? = nil) -> (status: Int32, out: String, err: String) {
    let r = sh("/usr/bin/env", ["python3", "-I", "-c", code] + args, input: input)
    return (r.status, String(decoding: r.out, as: UTF8.self), r.err)
}

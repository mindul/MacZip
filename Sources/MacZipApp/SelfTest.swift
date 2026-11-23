import AppKit
import MacZipCore

/// `MACZIP_SELFTEST=1`로 실행하면 실제 AppModel로 사용자 흐름을 따라가 본 뒤 종료한다.
/// 화면 없이 앱 코드의 크래시·상태 오류를 잡기 위한 회귀 점검(통과 시 종료 코드 0).
@MainActor
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["MACZIP_SELFTEST"] == "1" }

    static func run() -> Never {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maczip-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try? Data("hello".utf8).write(to: file)

        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        let model = AppModel()
        check(model.encryption == .aes256, "기본 암호 방식은 AES-256")
        // 파일 선택 창에서 고른 것과 같은 경로(reset이 비밀번호를 비움)
        model.handlePicked([file])
        check({ if case .ready(.compress, _) = model.phase { return true }; return false }(), "선택 후 압축 준비 상태")
        // 허용되지 않는 문자는 걸러져야 함
        model.updatePassword("ab한글c1")
        check(model.password == "abc1", "한글 제거: \(model.password)")
        check(model.rejectedPasswordInput, "거부 안내 표시")
        model.updatePasswordConfirmation("abc1")
        check(model.passwordStatus == .ok, "두 칸 일치")
        // 초기화와 끌어다 놓기도 같은 setter를 지남
        model.encryption = .zipCrypto
        model.reset()
        check(model.encryption == .zipCrypto, "고른 암호 방식은 초기화 후에도 유지")
        model.encryption = .aes256
        check(model.password.isEmpty && model.passwordConfirmation.isEmpty && !model.rejectedPasswordInput, "초기화")
        model.handleDrop([file])
        check({ if case .ready(.compress, _) = model.phase { return true }; return false }(), "끌어다 놓기 후 압축 준비 상태")
        model.reset()

        // Finder 우클릭 → '맥집에서 압축하기'(서비스)로 파일을 받은 경우
        let provider = ServiceProvider(model: model)
        let board = NSPasteboard(name: NSPasteboard.Name("maczip-selftest-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([file as NSURL, dir as NSURL])
        var serviceError: NSString = ""
        provider.compressInMacZip(board, userData: "", error: &serviceError)
        check(serviceError.length == 0, "서비스 오류 없음: \(serviceError)")
        check({ if case let .ready(.compress, urls) = model.phase { return urls.count == 2 }; return false }(), "서비스로 받은 2개 항목 압축 준비")
        model.reset()
        // '맥집에서 압축하기'는 .zip 파일도 풀지 않고 압축한다.
        let zipFile = dir.appendingPathComponent("이미 압축된.zip")
        try? Data("not really a zip".utf8).write(to: zipFile)
        board.clearContents()
        board.writeObjects([zipFile as NSURL])
        provider.compressInMacZip(board, userData: "", error: &serviceError)
        check({ if case let .ready(.compress, urls) = model.phase { return urls == [zipFile] }; return false }(), "서비스로 받은 .zip도 압축 준비")
        model.reset()
        board.clearContents()
        provider.compressInMacZip(board, userData: "", error: &serviceError)
        check(serviceError.length > 0, "빈 선택은 오류 메시지")
        board.releaseGlobally()

        if failures.isEmpty {
            print("SELFTEST OK")
            exit(0)
        }
        print("SELFTEST FAILED: " + failures.joined(separator: ", "))
        exit(1)
    }
}

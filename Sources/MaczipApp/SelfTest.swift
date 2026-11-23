import AppKit
import MaczipCore

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
        model.reset()
        check(model.password.isEmpty && model.passwordConfirmation.isEmpty && !model.rejectedPasswordInput, "초기화")
        model.handleDrop([file])
        check({ if case .ready(.compress, _) = model.phase { return true }; return false }(), "끌어다 놓기 후 압축 준비 상태")
        model.reset()

        if failures.isEmpty {
            print("SELFTEST OK")
            exit(0)
        }
        print("SELFTEST FAILED: " + failures.joined(separator: ", "))
        exit(1)
    }
}

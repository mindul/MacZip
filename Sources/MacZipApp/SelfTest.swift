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

        // 창 없이 푸는 부품: 비밀번호 창·알림 창은 가짜로 바꿔 끼운다(처음엔 틀린 비밀번호, 다음엔 맞는 비밀번호)
        var passwordAnswers = ["wrong", "pw"]
        var passwordAsks: [Bool] = []          // 각 요청의 '다시 묻기' 여부
        var reports: [String] = []
        var idle = false
        var progressShown = 0, progressClosed = false
        let extractor = BackgroundExtractor(
            ui: .init(askPassword: { _, retry in passwordAsks.append(retry); return passwordAnswers.isEmpty ? nil : passwordAnswers.removeFirst() },
                      confirmLarge: { _, _ in true },
                      report: { reports.append($0) },
                      showProgress: { state in if state == nil { progressClosed = true } else { progressShown += 1 } }),
            progressDelay: 0,
            onIdle: { idle = true })
        func waitIdle() {
            let deadline = Date().addingTimeInterval(10)
            while !idle, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }

        // Finder 우클릭 → '맥집에서 압축하기'(서비스)로 파일을 받은 경우
        let provider = ServiceProvider(model: model, extractor: extractor)
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

        // '맥집에서 압축 풀기' / '다음으로 열기': 창 없이 차례로 푼다
        let srcDir = dir.appendingPathComponent("src"), outDir = dir.appendingPathComponent("out")
        let fm = FileManager.default
        for d in ["src/pf", "src/ef", "out"] { try? fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
        try? Data("plain".utf8).write(to: srcDir.appendingPathComponent("pf/p.txt"))
        try? Data("secret".utf8).write(to: srcDir.appendingPathComponent("ef/e.txt"))
        let plainZip = try? Archiver.compress(inputs: [srcDir.appendingPathComponent("pf")], password: nil, progress: { _ in }, isCancelled: { false })
        let encZip = try? Archiver.compress(inputs: [srcDir.appendingPathComponent("ef")], password: "pw", encryption: .aes256, progress: { _ in }, isCancelled: { false })
        if let plainZip, let encZip {
            let p = outDir.appendingPathComponent("pf.zip"), e = outDir.appendingPathComponent("ef.zip")
            try? fm.moveItem(at: plainZip.output, to: p)
            try? fm.moveItem(at: encZip.output, to: e)
            board.clearContents()
            board.writeObjects([e as NSURL, p as NSURL, file as NSURL])   // zip이 아닌 항목은 건너뛴다
            provider.extractInMacZip(board, userData: "", error: &serviceError)
            waitIdle()
            check(idle, "창 없이 풀기: 끝까지 진행")
            check(fm.fileExists(atPath: outDir.appendingPathComponent("pf/pf/p.txt").path), "창 없이 풀기: 일반 zip 풀림")
            check(fm.fileExists(atPath: outDir.appendingPathComponent("ef/ef/e.txt").path), "창 없이 풀기: 암호 zip 풀림")
            check(passwordAsks == [false, true], "틀린 비밀번호면 다시 물음: \(passwordAsks)")
            check(reports.isEmpty, "성공하면 알림 없음: \(reports)")
            check({ if case .idle = model.phase { return true }; return false }(), "창 없이 풀기는 창 상태를 바꾸지 않음")
            check(progressShown > 0 && progressClosed, "진행 창 표시 후 닫힘: \(progressShown) \(progressClosed)")
        } else {
            check(false, "자체 점검용 zip 만들기")
        }

        // 진행 창의 [취소]: 지금 풀던 zip과 기다리던 zip을 모두 멈추고, 알림 없이 끝난다.
        let bigDir = dir.appendingPathComponent("big")
        for i in 0..<400 {
            try? fm.createDirectory(at: bigDir.appendingPathComponent("d\(i % 20)"), withIntermediateDirectories: true)
            try? Data(repeating: UInt8(i % 251), count: 4096).write(to: bigDir.appendingPathComponent("d\(i % 20)/f\(i).bin"))
        }
        let cancelDir = dir.appendingPathComponent("cancel")
        try? fm.createDirectory(at: cancelDir, withIntermediateDirectories: true)
        if let big = try? Archiver.compress(inputs: [bigDir], password: nil, progress: { _ in }, isCancelled: { false }) {
            let first = cancelDir.appendingPathComponent("first.zip"), second = cancelDir.appendingPathComponent("second.zip")
            try? fm.moveItem(at: big.output, to: first)
            try? fm.copyItem(at: first, to: second)
            var cancelIdle = false, cancelReports: [String] = [], states: [BackgroundExtractor.ProgressState] = []
            let canceller = BackgroundExtractor(
                ui: .init(askPassword: { _, _ in nil }, confirmLarge: { _, _ in true },
                          report: { cancelReports.append($0) },
                          showProgress: { state in
                              guard let state else { return }
                              states.append(state)
                              if states.count == 1 { state.onCancel() }   // 처음 뜨자마자 [취소]
                          }),
                progressDelay: 0,
                onIdle: { cancelIdle = true })
            canceller.enqueue([first, second])
            let deadline = Date().addingTimeInterval(10)
            while !cancelIdle, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(cancelIdle, "취소: 끝까지 진행")
            check(states.first.map { $0.index == 1 && $0.total == 2 && $0.zipName == "first.zip" } ?? false, "진행 창 내용(1/2)")
            check(!fm.fileExists(atPath: cancelDir.appendingPathComponent("second").path), "취소: 기다리던 zip은 풀지 않음")
            let leftovers = ((try? fm.contentsOfDirectory(atPath: cancelDir.path)) ?? []).filter { $0.contains("maczip-tmp") }
            check(leftovers.isEmpty, "취소: 임시 폴더 없음 \(leftovers)")
            check(cancelReports.isEmpty, "취소: 알림 없음 \(cancelReports)")
        } else {
            check(false, "취소 점검용 zip 만들기")
        }
        // zip이 하나도 없으면 안내
        idle = false
        board.clearContents()
        board.writeObjects([file as NSURL])
        provider.extractInMacZip(board, userData: "", error: &serviceError)
        waitIdle()
        check(reports.contains { $0.contains("zip 파일이 아니") }, "zip이 아니면 안내: \(reports)")
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

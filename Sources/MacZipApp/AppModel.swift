import AppKit
import MacZipCore
import Observation

/// 백그라운드 작업과 공유하는 취소 플래그.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// 진행 상황을 UI에 너무 자주 보내지 않도록 거른다.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldEmit() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) > 0.05 else { return false }
            last = now
            return true
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case idle
        case ready(OperationMode, [URL])
        case needsPassword([URL])
        case confirmLarge(bytes: UInt64, [URL])
        case working(ArchiveProgress)
        case done(String)
        case failed(String)
    }

    var phase: Phase = .idle
    /// 압축 비밀번호. 화면 입력은 반드시 updatePassword(_:)를 거쳐 걸러진다.
    /// (didSet으로 거르면 @Observable 속성에서 자기 자신을 무한히 다시 부르는 문제가 있어 쓰지 않는다.)
    private(set) var password = ""
    private(set) var passwordConfirmation = ""
    /// 허용되지 않는 문자를 지운 적이 있으면 안내 문구를 보여 준다.
    private(set) var rejectedPasswordInput = false
    /// 압축 암호 방식. 기본은 AES-256이며, 고른 값은 앱을 끌 때까지 유지한다(reset에서 되돌리지 않음).
    var encryption: EncryptionMethod = .aes256

    /// 압축 비밀번호 입력: 영문·숫자·기호 외의 문자는 지우고 저장한다.
    func updatePassword(_ value: String) { password = allowedPassword(value) }
    func updatePasswordConfirmation(_ value: String) { passwordConfirmation = allowedPassword(value) }

    private func allowedPassword(_ value: String) -> String {
        let allowed = PasswordEntry.allowedOnly(value)
        if allowed != value { rejectedPasswordInput = true }
        return allowed
    }
    var passwordStatus: PasswordEntry {
        PasswordEntry.check(password: password, confirmation: passwordConfirmation)
    }
    private(set) var passwordError: String?
    private(set) var resultURL: URL?
    private(set) var currentURLs: [URL] = []
    private(set) var workingMode: OperationMode = .compress
    private var cancelFlag: CancelFlag?
    private var archiveIsEncrypted = false

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// 첫 화면(또는 완료·실패 화면)에서만 클릭으로 파일을 고를 수 있다.
    var canPick: Bool {
        switch phase {
        case .idle, .done, .failed: return true
        default: return false
        }
    }

    // MARK: 사용자 동작

    func handleDrop(_ urls: [URL]) {
        guard !isWorking, let mode = DropClassifier.mode(for: urls) else { return }
        reset()
        currentURLs = urls
        switch mode {
        case .compress:
            phase = .ready(.compress, urls)
        case .extract:
            prepareExtract(urls)
        }
    }

    /// 파일 선택 창에서 파일·폴더를 여러 개 골라 압축 준비 상태로 간다.
    func chooseFilesToCompress() {
        guard canPick else { return }
        let panel = NSOpenPanel()
        panel.title = "압축할 파일과 폴더 선택"
        panel.prompt = "선택"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        handlePicked(panel.urls)
    }

    /// 선택 창에서 고른 항목은 .zip 파일이어도 항상 압축한다.
    func handlePicked(_ urls: [URL]) {
        guard !isWorking, !urls.isEmpty else { return }
        reset()
        currentURLs = urls
        phase = .ready(.compress, urls)
    }

    func startCompress() {
        guard case let .ready(.compress, urls) = phase else { return }
        let status = passwordStatus
        guard status == .ok || status == .none else { return }
        KeyboardLayout.leaveASCIIField()
        let pw = status == .ok ? password : nil
        password = ""
        passwordConfirmation = ""
        run(.compress, urls, password: pw)
    }

    func submitExtractPassword(_ pw: String) {
        guard case let .needsPassword(urls) = phase else { return }
        passwordError = nil
        run(.extract, urls, password: pw)
    }

    func confirmLargeExtract() {
        guard case let .confirmLarge(_, urls) = phase else { return }
        if archiveIsEncrypted { phase = .needsPassword(urls) } else { run(.extract, urls, password: nil) }
    }

    func cancel() { cancelFlag?.set() }

    func reset() {
        cancelFlag?.set()
        cancelFlag = nil
        phase = .idle
        password = ""
        passwordConfirmation = ""
        rejectedPasswordInput = false
        KeyboardLayout.leaveASCIIField()
        passwordError = nil
        resultURL = nil
        archiveIsEncrypted = false
    }

    func revealResult() {
        guard let resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
    }

    // MARK: 해제 준비

    private func prepareExtract(_ urls: [URL]) {
        guard let zip = urls.first else { return }
        do {
            let info = try Archiver.inspect(zip: zip)
            archiveIsEncrypted = info.isEncrypted
            let zipSize = UInt64((try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let total = info.totalUncompressedBytes
            let suspicious = total > (1 << 30) && zipSize > 0 && total / zipSize > 1000
            if total > Archiver.confirmBytes || suspicious {
                phase = .confirmLarge(bytes: total, urls)
            } else if info.isEncrypted {
                phase = .needsPassword(urls)
            } else {
                run(.extract, urls, password: nil)
            }
        } catch {
            appLog.notice("압축 풀기 준비 실패: \(String(describing: error), privacy: .public)")
            phase = .failed(Self.message(for: (error as? ZipError) ?? .io(error.localizedDescription)))
        }
    }

    // MARK: 실행

    private func run(_ mode: OperationMode, _ urls: [URL], password: String?) {
        let encryption = self.encryption
        let flag = CancelFlag()
        cancelFlag = flag
        workingMode = mode
        phase = .working(ArchiveProgress(completedBytes: 0, totalBytes: 0, currentName: ""))
        let throttle = ProgressThrottle()
        let report: @Sendable (ArchiveProgress) -> Void = { p in
            guard throttle.shouldEmit() else { return }
            Task { @MainActor [weak self] in
                guard let self, !flag.isSet, case .working = self.phase else { return }
                self.phase = .working(p)
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                switch mode {
                case .compress:
                    let r = try Archiver.compress(inputs: urls, password: password, encryption: encryption, progress: report,
                                                  isCancelled: { flag.isSet })
                    await self?.finishCompress(r, flag: flag)
                case .extract:
                    let r = try Archiver.extract(zip: urls[0], password: password, progress: report,
                                                 isCancelled: { flag.isSet })
                    await self?.finishExtract(r, flag: flag)
                }
            } catch {
                await self?.fail((error as? ZipError) ?? .io(error.localizedDescription), urls: urls, flag: flag)
            }
        }
    }

    private func finishCompress(_ r: CompressResult, flag: CancelFlag) {
        guard cancelFlag === flag else { return }
        cancelFlag = nil
        resultURL = r.output
        var message = "압축 완료: \(r.output.lastPathComponent) (\(r.entryCount)개 항목)"
        if r.skippedSymlinks > 0 { message += "\n심볼릭 링크 \(r.skippedSymlinks)개는 건너뛰었습니다." }
        phase = .done(message)
    }

    private func finishExtract(_ r: ExtractResult, flag: CancelFlag) {
        appLog.notice("압축 풀기 완료: \(r.extractedCount)개, 실패 \(r.failures.count)개")
        guard cancelFlag === flag else { return }
        cancelFlag = nil
        resultURL = r.outputFolder
        var message = "압축 풀기 완료: \(r.outputFolder.lastPathComponent) (\(r.extractedCount)개 파일)"
        if r.skippedSymlinks > 0 { message += "\n심볼릭 링크 \(r.skippedSymlinks)개는 건너뛰었습니다." }
        if let summary = r.failureSummary {
            message += "\n풀지 못한 항목이 있습니다.\n\(summary)"
        }
        phase = .done(message)
    }

    private func fail(_ error: ZipError, urls: [URL], flag: CancelFlag) {
        appLog.notice("작업 실패: \(error.userMessage, privacy: .public)")
        guard cancelFlag === flag else { return }
        cancelFlag = nil
        switch error {
        case .wrongPassword:
            passwordError = "비밀번호가 맞지 않습니다."
            phase = .needsPassword(urls)
        case .passwordRequired:
            phase = .needsPassword(urls)
        case .cancelled:
            phase = .idle
        default:
            phase = .failed(Self.message(for: error))
        }
    }

    static func message(for error: ZipError) -> String { error.userMessage }
}

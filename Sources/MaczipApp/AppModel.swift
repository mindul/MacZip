import AppKit
import MaczipCore
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
    var password = ""
    private(set) var passwordError: String?
    private(set) var resultURL: URL?
    private(set) var currentURLs: [URL] = []
    private(set) var workingMode: OperationMode = .compress
    private var cancelFlag: CancelFlag?
    private var archiveIsEncrypted = false

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

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

    func startCompress() {
        guard case let .ready(.compress, urls) = phase else { return }
        let pw = password.isEmpty ? nil : password
        password = ""
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
            phase = .failed(Self.message(for: (error as? ZipError) ?? .io(error.localizedDescription)))
        }
    }

    // MARK: 실행

    private func run(_ mode: OperationMode, _ urls: [URL], password: String?) {
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
                    let r = try Archiver.compress(inputs: urls, password: password, progress: report,
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
        guard cancelFlag === flag else { return }
        cancelFlag = nil
        resultURL = r.outputFolder
        var message = "압축 풀기 완료: \(r.outputFolder.lastPathComponent) (\(r.extractedCount)개 파일)"
        if r.skippedSymlinks > 0 { message += "\n심볼릭 링크 \(r.skippedSymlinks)개는 건너뛰었습니다." }
        if !r.failures.isEmpty {
            let names = r.failures.prefix(3).map(\.name).joined(separator: ", ")
            message += "\n\(r.failures.count)개 항목은 풀지 못했습니다: \(names)\(r.failures.count > 3 ? " 외" : "")"
        }
        phase = .done(message)
    }

    private func fail(_ error: ZipError, urls: [URL], flag: CancelFlag) {
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

    static func message(for error: ZipError) -> String {
        switch error {
        case .notAZip: return "zip 파일이 아니거나 손상되었습니다."
        case .corrupt: return "압축 파일이 손상되었습니다."
        case let .unsupportedMethod(m): return "지원하지 않는 압축 방식입니다. (방식 \(m))"
        case .unsupportedAES: return "AES 암호화는 지원하지 않습니다."
        case .passwordRequired: return "비밀번호가 필요합니다."
        case .wrongPassword: return "비밀번호가 맞지 않습니다."
        case let .crcMismatch(entry): return "파일이 손상되었습니다: \(entry)"
        case let .unsafePath(name): return "안전하지 않은 경로라서 건너뛰었습니다: \(name)"
        case .tooLarge: return "4GB 이상의 파일은 지원하지 않습니다."
        case .cancelled: return "취소했습니다."
        case let .io(detail): return "파일을 읽거나 쓸 수 없습니다. (\(detail))"
        }
    }
}

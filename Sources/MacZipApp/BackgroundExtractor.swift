import AppKit
import MacZipCore

/// 맥집 창을 띄우지 않고 zip을 차례로 푼다(Finder '맥집에서 압축 풀기', '다음으로 열기').
/// 비밀번호·대용량 확인·오류 알림이 필요할 때만 작은 대화상자를 띄우고,
/// progressDelay보다 오래 걸리면 진행 창([취소] 포함)을 띄운다.
@MainActor
final class BackgroundExtractor {
    /// 진행 창에 보여 줄 내용.
    struct ProgressState {
        let zipName: String
        /// 이번에 받은 zip 중 몇 번째인지(1부터)와 전체 개수.
        let index: Int
        let total: Int
        let fraction: Double
        /// [취소]를 눌렀을 때: 지금 풀던 zip과 기다리던 zip을 모두 취소한다.
        let onCancel: @MainActor () -> Void
    }

    struct UI {
        /// 비밀번호 요청. retry는 직전 비밀번호가 틀렸는지. nil이나 빈 값이면 그 zip은 건너뛴다.
        var askPassword: @MainActor (_ zipName: String, _ retry: Bool) -> String?
        /// 풀면 매우 커지는 zip을 계속 풀지 확인한다.
        var confirmLarge: @MainActor (_ zipName: String, _ bytes: UInt64) -> Bool
        /// 실패·일부 실패를 알린다. 성공하면 호출하지 않는다.
        var report: @MainActor (_ message: String) -> Void
        /// 진행 창을 띄우거나 갱신한다. nil이면 닫는다.
        var showProgress: @MainActor (_ state: ProgressState?) -> Void
    }

    private let ui: UI
    private let onIdle: @MainActor () -> Void
    private let progressDelay: TimeInterval
    private var queue: [URL] = []
    private(set) var isBusy = false

    // 이번 묶음(쉬지 않고 이어서 푼 zip들)의 진행 상황
    private var taken = 0                 // 지금까지 꺼낸 zip 수
    private var current: (name: String, index: Int)?
    private var fraction = 0.0
    private var progressSince = Date()    // 이 시각부터 progressDelay가 지나면 진행 창을 띄운다
    private var progressVisible = false
    private var cancelFlag: CancelFlag?

    init(ui: UI, progressDelay: TimeInterval = 1, onIdle: @escaping @MainActor () -> Void) {
        self.ui = ui
        self.progressDelay = progressDelay
        self.onIdle = onIdle
    }

    /// zip 파일들을 차례로 푼다. zip이 아닌 항목은 건너뛴다.
    func enqueue(_ urls: [URL]) {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        appLog.notice("창 없이 풀기 요청: 항목 \(urls.count)개, zip \(zips.count)개")
        guard !zips.isEmpty else {
            modal { ui.report("zip 파일이 아니라서 풀 수 없어요.") }
            if !isBusy { onIdle() }
            return
        }
        queue += zips
        if !isBusy {
            taken = 0
            progressSince = Date()
            next()
        } else {
            refreshProgress()   // 전체 개수가 늘었다
        }
    }

    /// 지금 풀던 zip과 기다리던 zip을 모두 취소한다.
    func cancelAll() {
        queue.removeAll()
        cancelFlag?.set()
    }

    private func next() {
        guard !queue.isEmpty else {
            current = nil
            hideProgress()
            isBusy = false
            onIdle()
            return
        }
        isBusy = true
        let zip = queue.removeFirst()
        taken += 1
        current = (zip.lastPathComponent, taken)
        fraction = 0
        refreshProgress()
        let name = zip.lastPathComponent
        let info: ArchiveInfo
        do {
            info = try Archiver.inspect(zip: zip)
        } catch {
            modal { ui.report("‘\(name)’을(를) 풀 수 없어요. \(((error as? ZipError) ?? .io(error.localizedDescription)).userMessage)") }
            next()
            return
        }
        let zipSize = UInt64((try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let total = info.totalUncompressedBytes
        let suspicious = total > (1 << 30) && zipSize > 0 && total / zipSize > 1000
        if total > Archiver.confirmBytes || suspicious, !modal({ ui.confirmLarge(name, total) }) {
            next()
            return
        }
        extract(zip, encrypted: info.isEncrypted, retry: false)
    }

    private func extract(_ zip: URL, encrypted: Bool, retry: Bool) {
        var password: String?
        if encrypted {
            guard let pw = modal({ ui.askPassword(zip.lastPathComponent, retry) }), !pw.isEmpty else {
                next()
                return
            }
            password = pw
        }
        let pw = password
        let flag = CancelFlag()
        cancelFlag = flag
        let throttle = ProgressThrottle()
        let report: @Sendable (ArchiveProgress) -> Void = { p in
            guard throttle.shouldEmit() else { return }
            Task { @MainActor [weak self] in self?.progressChanged(p.fraction, flag: flag) }
        }
        // 이 객체는 앱이 켜져 있는 동안 유지되므로 강하게 잡아도 된다.
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result { try Archiver.extract(zip: zip, password: pw, progress: report, isCancelled: { flag.isSet }) }
            await finish(zip, encrypted: encrypted, result: result)
        }
    }

    private func finish(_ zip: URL, encrypted: Bool, result: Result<ExtractResult, Error>) {
        cancelFlag = nil
        let name = zip.lastPathComponent
        switch result {
        case let .success(r):
            appLog.notice("창 없이 풀기 완료: \(r.extractedCount)개, 실패 \(r.failures.count)개")
            if let summary = r.failureSummary {
                modal { ui.report("‘\(name)’에서 풀지 못한 항목이 있어요.\n\(summary)") }
            }
        case let .failure(error):
            let zipError = (error as? ZipError) ?? .io(error.localizedDescription)
            if zipError == .wrongPassword || zipError == .passwordRequired {
                extract(zip, encrypted: true, retry: true)
                return
            }
            if zipError == .cancelled {
                appLog.notice("창 없이 풀기 취소")
            } else {
                modal { ui.report("‘\(name)’을(를) 풀 수 없어요. \(zipError.userMessage)") }
            }
        }
        next()
    }

    // MARK: 진행 창

    private func progressChanged(_ value: Double, flag: CancelFlag) {
        guard cancelFlag === flag, !flag.isSet else { return }
        fraction = value
        refreshProgress()
    }

    /// 지연 시간이 지났으면 진행 창을 띄우거나 갱신한다.
    private func refreshProgress() {
        guard let current, progressVisible || Date().timeIntervalSince(progressSince) >= progressDelay else { return }
        progressVisible = true
        ui.showProgress(ProgressState(zipName: current.name, index: current.index, total: taken + queue.count,
                                      fraction: fraction, onCancel: { [weak self] in self?.cancelAll() }))
    }

    private func hideProgress() {
        guard progressVisible else { return }
        progressVisible = false
        ui.showProgress(nil)
    }

    /// 대화상자를 띄우는 동안에는 진행 창을 숨기고, 닫은 뒤에는 지연 시간을 다시 센다.
    private func modal<T>(_ body: () -> T) -> T {
        hideProgress()
        defer { progressSince = Date() }
        return body()
    }
}

extension BackgroundExtractor.UI {
    /// 실제 앱에서 쓰는 대화상자들.
    @MainActor static var alerts: BackgroundExtractor.UI {
        let panel = ExtractProgressPanel()
        return .init(
            askPassword: { name, retry in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = retry ? "비밀번호가 맞지 않습니다" : "비밀번호가 필요합니다"
                alert.informativeText = "‘\(name)’의 비밀번호를 입력하세요."
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                alert.accessoryView = field
                alert.addButton(withTitle: "풀기")
                alert.addButton(withTitle: "취소")
                alert.window.initialFirstResponder = field
                return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
            },
            confirmLarge: { name, bytes in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "큰 압축 파일"
                alert.informativeText = "‘\(name)’을(를) 풀면 약 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))가 됩니다. 계속할까요?"
                alert.addButton(withTitle: "계속")
                alert.addButton(withTitle: "취소")
                return alert.runModal() == .alertFirstButtonReturn
            },
            report: { message in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "맥집"
                alert.informativeText = message
                alert.runModal()
            },
            showProgress: { state in panel.update(state) })
    }
}

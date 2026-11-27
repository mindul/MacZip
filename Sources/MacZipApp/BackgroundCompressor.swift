import AppKit
import MacZipCore

/// 맥집 창을 띄우지 않고 바로 압축한다(Finder '맥집에서 압축하기').
/// 비밀번호 없이, 고른 항목 옆에 zip을 만든다. 파일 하나(또는 폴더 하나)면 그 이름으로,
/// 여러 개면 상위 폴더 이름으로 만든다. 오류가 났을 때만 알림을 띄우고,
/// progressDelay보다 오래 걸리면 진행 창([취소] 포함)을 띄운다.
@MainActor
final class BackgroundCompressor {
    struct UI {
        /// 실패를 알린다. 성공하면 호출하지 않는다.
        var report: @MainActor (_ message: String) -> Void
        /// 진행 창을 띄우거나 갱신한다. nil이면 닫는다.
        var showProgress: @MainActor (_ state: BackgroundExtractor.ProgressState?) -> Void
    }

    private let ui: UI
    private let onIdle: @MainActor () -> Void
    private let progressDelay: TimeInterval
    private var queue: [[URL]] = []
    private(set) var isBusy = false

    // 이번 묶음(쉬지 않고 이어서 만든 zip들)의 진행 상황
    private var taken = 0
    private var current: (name: String, index: Int)?
    private var fraction = 0.0
    private var progressSince = Date()
    private var progressVisible = false
    private var cancelFlag: CancelFlag?

    init(ui: UI, progressDelay: TimeInterval = 1, onIdle: @escaping @MainActor () -> Void) {
        self.ui = ui
        self.progressDelay = progressDelay
        self.onIdle = onIdle
    }

    /// 고른 항목들을 zip 하나로 압축한다. 선택이 .zip 파일이어도 풀지 않고 압축한다.
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        appLog.notice("창 없이 압축 요청: 항목 \(urls.count)개")
        queue.append(urls)
        if !isBusy {
            taken = 0
            progressSince = Date()
            next()
        } else {
            refreshProgress()
        }
    }

    /// 지금 만들던 zip과 기다리던 요청을 모두 취소한다.
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
        let urls = queue.removeFirst()
        taken += 1
        let name = Archiver.zipName(for: urls)
        current = (name, taken)
        fraction = 0
        refreshProgress()

        let flag = CancelFlag()
        cancelFlag = flag
        let throttle = ProgressThrottle()
        let report: @Sendable (ArchiveProgress) -> Void = { p in
            guard throttle.shouldEmit() else { return }
            Task { @MainActor [weak self] in self?.progressChanged(p.fraction, flag: flag) }
        }
        // 이 객체는 앱이 켜져 있는 동안 유지되므로 강하게 잡아도 된다.
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result { try Archiver.compress(inputs: urls, password: nil, progress: report, isCancelled: { flag.isSet }) }
            await finish(name, result: result)
        }
    }

    private func finish(_ name: String, result: Result<CompressResult, Error>) {
        cancelFlag = nil
        switch result {
        case let .success(r):
            appLog.notice("창 없이 압축 완료: \(r.entryCount)개 항목")
        case let .failure(error):
            let zipError = (error as? ZipError) ?? .io(error.localizedDescription)
            if zipError == .cancelled {
                appLog.notice("창 없이 압축 취소")
            } else {
                modal { ui.report("‘\(name)’을(를) 압축할 수 없어요. \(zipError.userMessage)") }
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

    private func refreshProgress() {
        guard let current, progressVisible || Date().timeIntervalSince(progressSince) >= progressDelay else { return }
        progressVisible = true
        ui.showProgress(.init(zipName: current.name, index: current.index, total: taken + queue.count,
                              fraction: fraction, action: "압축하는 중",
                              onCancel: { [weak self] in self?.cancelAll() }))
    }

    private func hideProgress() {
        guard progressVisible else { return }
        progressVisible = false
        ui.showProgress(nil)
    }

    /// 알림을 띄우는 동안에는 진행 창을 숨기고, 닫은 뒤에는 지연 시간을 다시 센다.
    private func modal<T>(_ body: () -> T) -> T {
        hideProgress()
        defer { progressSince = Date() }
        return body()
    }
}

extension BackgroundCompressor.UI {
    @MainActor static var alerts: BackgroundCompressor.UI {
        let panel = ExtractProgressPanel()
        return .init(
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

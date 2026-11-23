import AppKit
import MacZipCore

/// 맥집 창을 띄우지 않고 zip을 차례로 푼다(Finder '맥집에서 압축 풀기', '다음으로 열기').
/// 비밀번호·대용량 확인·오류 알림이 필요할 때만 작은 대화상자를 띄운다.
@MainActor
final class BackgroundExtractor {
    struct UI {
        /// 비밀번호 요청. retry는 직전 비밀번호가 틀렸는지. nil이나 빈 값이면 그 zip은 건너뛴다.
        var askPassword: @MainActor (_ zipName: String, _ retry: Bool) -> String?
        /// 풀면 매우 커지는 zip을 계속 풀지 확인한다.
        var confirmLarge: @MainActor (_ zipName: String, _ bytes: UInt64) -> Bool
        /// 실패·일부 실패를 알린다. 성공하면 호출하지 않는다.
        var report: @MainActor (_ message: String) -> Void
    }

    private let ui: UI
    private let onIdle: @MainActor () -> Void
    private var queue: [URL] = []
    private(set) var isBusy = false

    init(ui: UI, onIdle: @escaping @MainActor () -> Void) {
        self.ui = ui
        self.onIdle = onIdle
    }

    /// zip 파일들을 차례로 푼다. zip이 아닌 항목은 건너뛴다.
    func enqueue(_ urls: [URL]) {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        appLog.notice("창 없이 풀기 요청: 항목 \(urls.count)개, zip \(zips.count)개")
        guard !zips.isEmpty else {
            ui.report("zip 파일이 아니라서 풀 수 없어요.")
            if !isBusy { onIdle() }
            return
        }
        queue += zips
        if !isBusy { next() }
    }

    private func next() {
        guard !queue.isEmpty else {
            isBusy = false
            onIdle()
            return
        }
        isBusy = true
        let zip = queue.removeFirst()
        let name = zip.lastPathComponent
        let info: ArchiveInfo
        do {
            info = try Archiver.inspect(zip: zip)
        } catch {
            ui.report("‘\(name)’을(를) 풀 수 없어요. \(((error as? ZipError) ?? .io(error.localizedDescription)).userMessage)")
            next()
            return
        }
        let zipSize = UInt64((try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let total = info.totalUncompressedBytes
        let suspicious = total > (1 << 30) && zipSize > 0 && total / zipSize > 1000
        if total > Archiver.confirmBytes || suspicious, !ui.confirmLarge(name, total) {
            next()
            return
        }
        extract(zip, encrypted: info.isEncrypted, retry: false)
    }

    private func extract(_ zip: URL, encrypted: Bool, retry: Bool) {
        var password: String?
        if encrypted {
            guard let pw = ui.askPassword(zip.lastPathComponent, retry), !pw.isEmpty else {
                next()
                return
            }
            password = pw
        }
        let pw = password
        // 이 객체는 앱이 켜져 있는 동안 유지되므로 강하게 잡아도 된다.
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result { try Archiver.extract(zip: zip, password: pw, progress: { _ in }, isCancelled: { false }) }
            await finish(zip, encrypted: encrypted, result: result)
        }
    }

    private func finish(_ zip: URL, encrypted: Bool, result: Result<ExtractResult, Error>) {
        let name = zip.lastPathComponent
        switch result {
        case let .success(r):
            appLog.notice("창 없이 풀기 완료: \(r.extractedCount)개, 실패 \(r.failures.count)개")
            if let summary = r.failureSummary {
                ui.report("‘\(name)’에서 풀지 못한 항목이 있어요.\n\(summary)")
            }
        case let .failure(error):
            let zipError = (error as? ZipError) ?? .io(error.localizedDescription)
            if zipError == .wrongPassword || zipError == .passwordRequired {
                extract(zip, encrypted: true, retry: true)
                return
            }
            if zipError != .cancelled {
                ui.report("‘\(name)’을(를) 풀 수 없어요. \(zipError.userMessage)")
            }
        }
        next()
    }
}

extension BackgroundExtractor.UI {
    /// 실제 앱에서 쓰는 대화상자들.
    static var alerts: BackgroundExtractor.UI {
        .init(
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
            })
    }
}

import AppKit
import MacZipCore
import os
import SwiftUI

/// 서비스·실행 흐름 진단용 로그(파일 경로는 남기지 않는다). `log show --predicate 'subsystem == "dev.maczip.app"'`
let appLog = Logger(subsystem: "dev.maczip.app", category: "service")

/// Finder 우클릭 메뉴(macOS 서비스)를 처리한다. Info.plist의 NSServices → NSMessage 이름과 메서드 이름이 같아야 한다.
/// 두 서비스 모두 맥집 창을 띄우지 않는다.
/// - '맥집에서 압축하기'(compressInMacZip): 고른 항목은 .zip이어도 항상 압축한다.
///   하나면 그 이름으로, 여러 개면 상위 폴더 이름으로 바로 zip을 만든다.
/// - '맥집에서 압축 풀기'(extractInMacZip): .zip 파일에만 메뉴가 뜨며, 차례로 푼다.
final class ServiceProvider: NSObject {
    private let compressor: BackgroundCompressor
    private let extractor: BackgroundExtractor

    init(compressor: BackgroundCompressor, extractor: BackgroundExtractor) {
        self.compressor = compressor
        self.extractor = extractor
    }

    @objc func compressInMacZip(_ pasteboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(pasteboard, error: error) { [compressor] urls in compressor.enqueue(urls) }
    }

    @objc func extractInMacZip(_ pasteboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(pasteboard, error: error) { [extractor] urls in extractor.enqueue(urls) }
    }

    private func handle(_ pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString>,
                        action: @MainActor ([URL]) -> Void) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        appLog.notice("서비스 메시지 도착: 항목 \(urls.count)개, 형식 \(pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "-", privacy: .public)")
        guard !urls.isEmpty else {
            error.pointee = "선택한 파일이 없습니다."
            return
        }
        // 서비스 호출은 메인 스레드에서 온다.
        MainActor.assumeIsolated { action(urls) }
    }
}

/// 메인 창, 서비스 등록, 창 닫힘 시 종료를 담당한다.
/// 서비스로 앱이 실행되면 SwiftUI가 첫 창을 만들지 않으므로 창은 여기서 직접 만든다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var extractor = BackgroundExtractor(ui: .alerts, onIdle: { [weak self] in self?.quitIfNoWindow() })
    private lazy var compressor = BackgroundCompressor(ui: .alerts, onIdle: { [weak self] in self?.quitIfNoWindow() })
    private lazy var serviceProvider = ServiceProvider(compressor: compressor, extractor: extractor)
    private var window: NSWindow?

    /// 메인 창을 (없으면 만들어) 앞으로 가져온다.
    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: ContentView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "맥집"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 서비스로 앱이 실행된 경우에도 메시지를 받을 수 있게 실행 완료 전에 등록한다.
        NSApp.servicesProvider = serviceProvider
        appLog.notice("서비스 제공자 등록")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        // 파일 열기('다음으로 열기')나 서비스 때문에 실행됐다면 창을 띄우지 않는다.
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
        appLog.notice("실행: 일반 실행 \(isDefaultLaunch)")
        if isDefaultLaunch { showMainWindow() }
    }

    /// Finder '다음으로 열기'(또는 기본 앱으로 지정했을 때 더블클릭)로 받은 zip: 창 없이 푼다.
    func application(_ application: NSApplication, open urls: [URL]) {
        extractor.enqueue(urls)
    }

    /// 창 없이 풀거나 압축하는 작업이 모두 끝났을 때, 열린 창이 없으면 종료한다.
    private func quitIfNoWindow() {
        guard !(window?.isVisible ?? false), !extractor.isBusy, !compressor.isBusy else { return }
        NSApp.terminate(nil)
    }

    /// Dock 아이콘을 눌렀을 때 창이 없으면 다시 보여 준다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// 창을 닫으면 종료.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

import SwiftUI

@main
struct MacZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if SelfTest.isRequested { SelfTest.run() }
    }

    var body: some Scene {
        // 메인 창은 AppDelegate가 직접 만든다(서비스로 실행돼도 창이 뜨도록).
        // SwiftUI 앱 구조는 기본 메뉴(편집·복사·붙여넣기 등)를 위해 유지한다.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .appInfo) {
                    Button("맥집에 관하여") { Self.showAboutPanel() }
                }
            }
    }

    /// 표준 정보 창에서 빌드 번호 "(11)"을 숨기고, 버전 아래에 GitHub 링크를 표시한다.
    private static func showAboutPanel() {
        let urlString = "https://github.com/mindul/MacZip/"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: urlString, attributes: [
            .link: URL(string: urlString)!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: "",  // 빈 값이면 "(빌드 번호)"가 표시되지 않는다.
            .credits: credits,
        ])
    }
}

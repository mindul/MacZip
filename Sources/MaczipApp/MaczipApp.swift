import SwiftUI

@main
struct MaczipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if SelfTest.isRequested { SelfTest.run() }
    }

    var body: some Scene {
        // 메인 창은 AppDelegate가 직접 만든다(서비스로 실행돼도 창이 뜨도록).
        // SwiftUI 앱 구조는 기본 메뉴(편집·복사·붙여넣기 등)를 위해 유지한다.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

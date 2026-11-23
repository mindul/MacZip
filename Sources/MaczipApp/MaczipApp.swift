import SwiftUI

@main
struct MaczipApp: App {
    @State private var model = AppModel()

    init() {
        if SelfTest.isRequested { SelfTest.run() }
    }

    var body: some Scene {
        WindowGroup("Maczip") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

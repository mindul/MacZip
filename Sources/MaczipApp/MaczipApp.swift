import SwiftUI

@main
struct MaczipApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Maczip") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

import SwiftUI

@main
struct RewindApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
        }
    }
}

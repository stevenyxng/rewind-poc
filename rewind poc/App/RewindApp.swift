import SwiftUI

@main
struct RewindApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .task { await model.start() }
        }
    }
}

extension Appearance {
    /// nil = follow the phone's setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

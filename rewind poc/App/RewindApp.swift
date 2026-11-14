import SwiftUI

@main
struct RewindApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .task { await model.start() }
                .onOpenURL { url in
                    model.spotifyManager.handleCallback(url)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.spotifyManager.setAppActive(phase == .active)
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

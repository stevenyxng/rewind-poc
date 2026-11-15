import SwiftUI

@main
struct RewindApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.variantReady {
                    ContentView(model: model)
                } else {
                    Theme.background.ignoresSafeArea()
                }
            }
            .preferredColorScheme(model.settings.appearance.colorScheme)
            .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneEnteredBackground()
            default: break
            }
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

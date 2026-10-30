import SwiftUI
import UniformTypeIdentifiers

/// Portrait layout: menus / Now Playing on top, click wheel centered below.
struct ContentView: View {
    @Bindable var model: AppModel

    static let importTypes: [UTType] = [
        .mp3, .mpeg4Audio, .aiff, .wav, UTType("org.xiph.flac"), UTType("public.aac-audio"), .audio,
    ].compactMap { $0 }

    var body: some View {
        GeometryReader { geo in
            // The wheel is sized first (it's capped by the width on most phones); the display
            // takes everything above it, so Now Playing's artwork can be as large as possible.
            let wheelSize = min(geo.size.width - 72, geo.size.height * 0.45)
            let displayHeight = geo.size.height - wheelSize - 40
            VStack(spacing: 0) {
                DisplayView(model: model)
                    .frame(height: displayHeight)
                    .tutorialAnchor(.display)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                ClickWheelView { model.handle($0) }
                    .frame(width: wheelSize, height: wheelSize)
                    .tutorialAnchor(.wheel)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let step = model.tutorial.step,
                       let display = anchors[.display], let wheel = anchors[.wheel] {
                        TutorialOverlay(step: step, displayRect: proxy[display], wheelRect: proxy[wheel]) {
                            model.tutorial.finish()
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.tutorial.isActive)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .fileImporter(isPresented: $model.showingImporter, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { model.handleImport($0) }
    }
}

#Preview {
    ContentView(model: .live())
}

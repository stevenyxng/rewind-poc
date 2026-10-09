import SwiftUI

struct ContentView: View {
    @State private var model = MenuModel()

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScreenView(model: model)
                    .frame(height: geo.size.height * 0.42)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Spacer(minLength: 12)

                ClickWheelView { event in model.handle(event) }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [Color(white: 0.96), Color(white: 0.80)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

#Preview {
    ContentView()
}

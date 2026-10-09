import SwiftUI

/// The iPod "LCD": title bar + list with blue highlight bar.
struct ScreenView: View {
    let model: MenuModel
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                            row(item, selected: index == model.selectedIndex)
                                .id(index)
                        }
                    }
                }
                .scrollDisabled(true)
                .onChange(of: model.selectedIndex) { _, new in
                    proxy.scrollTo(new)
                }
            }
        }
        .background(Color(red: 0.93, green: 0.95, blue: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.5), lineWidth: 3))
    }

    private var titleBar: some View {
        ZStack {
            Text(model.title).font(.system(size: 15, weight: .bold))
            HStack {
                Image(systemName: model.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
                Spacer()
                Image(systemName: "battery.100")
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 10)
        }
        .foregroundStyle(.black.opacity(0.85))
        .frame(height: 26)
        .background(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.35)).frame(height: 1) }
    }

    private func row(_ text: String, selected: Bool) -> some View {
        HStack {
            Text(text).font(.system(size: 16, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .foregroundStyle(selected ? .white : .black)
        .background {
            if selected {
                LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 0.95),
                                        Color(red: 0.10, green: 0.35, blue: 0.80)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

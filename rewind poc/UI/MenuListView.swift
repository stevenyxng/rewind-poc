import SwiftUI

/// Classic iPod list: fixed-height rows, inverted selection bar, scroll indicator on the right.
struct MenuListView: View {
    let navigator: MenuNavigator
    let playingID: Track.ID?

    static let minRowHeight: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let rows = max(Int(geo.size.height / Self.minRowHeight), 1)
            let rowHeight = geo.size.height / CGFloat(rows)
            let items = navigator.items
            let frame = navigator.current
            let visible = Array(items.enumerated().dropFirst(frame.top).prefix(rows))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(visible, id: \.element.id) { index, item in
                        row(item, selected: index == frame.selected)
                            .frame(height: rowHeight)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                if items.count > rows {
                    ScrollIndicator(top: frame.top, visible: rows, count: items.count)
                        .frame(width: 4)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 3)
                }
            }
            .onAppear { navigator.visibleRows = rows }
            .onChange(of: rows) { _, new in navigator.visibleRows = new }
        }
    }

    private func row(_ item: MenuItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(item.title)
                .font(Theme.rowFont)
                .lineLimit(1)
            if item.id == playingID {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.selectionText : Theme.accent)
            }
            Spacer(minLength: 4)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.selectionText.opacity(0.75) : Theme.secondary)
                    .lineLimit(1)
            }
            if item.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.selectionText : Theme.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(selected ? Theme.selectionText : Theme.primary)
        .background(selected ? Theme.selectionFill : .clear)
    }
}

private struct ScrollIndicator: View {
    let top: Int
    let visible: Int
    let count: Int

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumb = max(h * CGFloat(visible) / CGFloat(count), 12)
            let maxTop = max(count - visible, 1)
            let offset = (h - thumb) * CGFloat(top) / CGFloat(maxTop)
            ZStack(alignment: .top) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.secondary)
                    .frame(height: thumb)
                    .offset(y: offset)
            }
        }
    }
}

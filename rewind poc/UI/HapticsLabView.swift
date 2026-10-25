import SwiftUI

/// Settings > Haptics Lab: live sliders for every `HapticParameter`, saved as you drag.
/// The wheel stays live: spin it to feel the detent ramp on a 24-step test strip.
struct HapticsLabView: View {
    let model: AppModel

    private var haptics: HapticsEngine { model.haptics }

    private static let groups: [(String, [HapticParameter])] = {
        var order: [String] = []
        var byGroup: [String: [HapticParameter]] = [:]
        for p in HapticParameter.allCases {
            if byGroup[p.spec.group] == nil { order.append(p.spec.group) }
            byGroup[p.spec.group, default: []].append(p)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detentStrip
                testButtons
                ForEach(Self.groups, id: \.0) { group, params in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(Theme.secondary)
                        ForEach(params) { slider(for: $0) }
                    }
                }
                HStack {
                    Button("Reset to Defaults") { haptics.tuning.reset() }
                        .disabled(haptics.tuning.isDefault)
                    Spacer()
                    Text(haptics.supportsCoreHaptics ? "Core Haptics" : "No Core Haptics (fallback)")
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.secondary)
                }
                .font(.system(size: 15, weight: .medium))
                .tint(Theme.accent)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
    }

    private var detentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spin the wheel to feel detents and walls")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 3) {
                ForEach(0..<AppModel.labDetentCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == model.labDetent ? Theme.primary : Theme.track)
                        .frame(height: 14)
                }
            }
        }
    }

    private var testButtons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], spacing: 6) {
            testButton("Detent") { haptics.detent() }
            testButton("Wall push") { haptics.previewWall() }
            testButton("Bump") { haptics.bump() }
            testButton("Button") { haptics.button(.menu) }
            testButton("Center") { haptics.button(.center) }
            testButton("Scrub slow") { haptics.scrubTick(rate: 2) }
            testButton("Scrub fast") { haptics.scrubTick(rate: 30) }
            testButton("30s mark") { haptics.scrubMark() }
        }
    }

    private func testButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.track))
        }
        .buttonStyle(.plain)
    }

    private func slider(for p: HapticParameter) -> some View {
        let binding = Binding(get: { haptics.tuning[p] }, set: { haptics.tuning[p] = $0 })
        let changed = haptics.tuning[p] != p.spec.defaultValue
        return VStack(spacing: 2) {
            HStack {
                Text(p.spec.label)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text(String(format: "%.2f", haptics.tuning[p]))
                    .font(Theme.monoFont)
                    .foregroundStyle(changed ? Theme.accent : Theme.secondary)
            }
            Slider(value: binding, in: p.spec.range)
                .tint(Theme.accent)
        }
    }
}

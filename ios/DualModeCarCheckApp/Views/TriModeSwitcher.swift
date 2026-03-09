import SwiftUI

struct TriModeSwitcher: View {
    let siteMode: LoginViewModel.SiteMode
    let onSelect: (LoginViewModel.SiteMode) -> Void

    private var selectedIndex: Int {
        switch siteMode {
        case .joe: 0
        case .dual: 1
        case .ignition: 2
        }
    }

    private var trackColor: Color {
        switch siteMode {
        case .joe: .green
        case .dual: .cyan
        case .ignition: .orange
        }
    }

    var body: some View {
        GeometryReader { geo in
            let segmentWidth = (geo.size.width - 6) / 3
            let thumbOffset = CGFloat(selectedIndex) * segmentWidth + 3

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.quaternarySystemFill))
                    .frame(height: 48)

                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [trackColor, trackColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: segmentWidth, height: 42)
                    .offset(x: thumbOffset)
                    .shadow(color: trackColor.opacity(0.35), radius: 6, y: 2)

                HStack(spacing: 0) {
                    segmentButton(
                        icon: "suit.spade.fill",
                        label: "JOE",
                        mode: .joe,
                        width: segmentWidth + 2
                    )

                    segmentButton(
                        icon: "arrow.triangle.branch",
                        label: "DUAL",
                        mode: .dual,
                        width: segmentWidth + 2
                    )

                    segmentButton(
                        icon: "flame.fill",
                        label: "IGN",
                        mode: .ignition,
                        width: segmentWidth + 2
                    )
                }
            }
            .frame(height: 48)
        }
        .frame(height: 48)
    }

    private func segmentButton(icon: String, label: String, mode: LoginViewModel.SiteMode, width: CGFloat) -> some View {
        Button {
            onSelect(mode)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
            }
            .frame(width: width, height: 48)
            .foregroundStyle(siteMode == mode ? .white : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

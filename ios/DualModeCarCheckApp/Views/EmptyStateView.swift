import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var accentColor: Color = .secondary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var animateIcon: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.08))
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(accentColor.opacity(0.6))
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: animateIcon)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.bold())

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
        .onAppear { animateIcon = true }
    }
}

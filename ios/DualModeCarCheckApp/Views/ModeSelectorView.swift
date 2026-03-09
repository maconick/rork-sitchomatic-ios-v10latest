import SwiftUI

struct ModeSelectorView: View {
    @AppStorage("productMode") private var modeRaw: String = ProductMode.ppsr.rawValue
    @Binding var hasSelectedMode: Bool

    @State private var animateIn: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image("SplitScreenBG")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                Color.black.opacity(0.55)

                VStack(spacing: 0) {
                    Spacer().frame(height: geo.safeAreaInsets.top + 24)

                    Text("SELECT MODE")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 20)
                        .opacity(animateIn ? 1 : 0)
                        .offset(y: animateIn ? 0 : -10)

                    let cardSpacing: CGFloat = 12
                    let horizontalPad: CGFloat = 20
                    let cardWidth = (geo.size.width - horizontalPad * 2 - cardSpacing) / 2
                    let cardHeight = cardWidth * 1.15

                    VStack(spacing: cardSpacing) {
                        HStack(spacing: cardSpacing) {
                            modeCard(
                                mode: .joe,
                                icon: "suit.spade.fill",
                                title: "Joe\nFortune",
                                subtitle: "Login testing",
                                color: .green,
                                width: cardWidth,
                                height: cardHeight,
                                delay: 0.05
                            )
                            modeCard(
                                mode: .ignition,
                                icon: "flame.fill",
                                title: "Ignition\nCasino",
                                subtitle: "Login testing",
                                color: .orange,
                                width: cardWidth,
                                height: cardHeight,
                                delay: 0.1
                            )
                        }
                        HStack(spacing: cardSpacing) {
                            modeCard(
                                mode: .dual,
                                icon: "arrow.triangle.branch",
                                title: "Dual\nMode",
                                subtitle: "Joe + Ignition",
                                color: .cyan,
                                width: cardWidth,
                                height: cardHeight,
                                delay: 0.15
                            )
                            modeCard(
                                mode: .ppsr,
                                icon: "car.side.fill",
                                title: "PPSR\nCarCheck",
                                subtitle: "VIN & card testing",
                                color: .teal,
                                width: cardWidth,
                                height: cardHeight,
                                delay: 0.2
                            )
                        }
                    }
                    .padding(.horizontal, horizontalPad)

                    Spacer()

                    Text("v8.0")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.bottom, geo.safeAreaInsets.bottom + 12)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.15)) {
                animateIn = true
            }
        }
    }

    private func modeCard(mode: ProductMode, icon: String, title: String, subtitle: String, color: Color, width: CGFloat, height: CGFloat, delay: Double) -> some View {
        Button {
            modeRaw = mode.rawValue
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                hasSelectedMode = true
            }
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.25), color.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(color.opacity(0.3), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(color)
                        .symbolEffect(.pulse, options: .repeating.speed(0.5))
                        .shadow(color: color.opacity(0.5), radius: 8)
                        .padding(.bottom, 12)

                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(2)
                        .shadow(color: .black.opacity(0.4), radius: 3)

                    Spacer()

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    HStack(spacing: 4) {
                        Text("ENTER")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(color.opacity(0.7))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(color.opacity(0.5))
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(y: animateIn ? 0 : 20)
        .animation(.spring(duration: 0.5, bounce: 0.15).delay(delay), value: animateIn)
        .sensoryFeedback(.impact(weight: .medium), trigger: modeRaw)
    }
}

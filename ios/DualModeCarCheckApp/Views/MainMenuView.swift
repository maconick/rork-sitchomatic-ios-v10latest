import SwiftUI

struct MainMenuView: View {
    @Binding var activeMode: ActiveAppMode?
    @State private var animateIn: Bool = false
    @State private var nordService = NordVPNService.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image("MainMenuBG")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                Color.black.opacity(0.3)

                VStack(spacing: 0) {
                    Spacer().frame(height: geo.safeAreaInsets.top + 12)

                    profileSwitcher
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    HStack(spacing: 0) {
                        joeZone(geo: geo)
                        ignitionZone(geo: geo)
                    }
                    .frame(height: (geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom) * 0.28)

                    HStack(spacing: 0) {
                        splitTestZone(geo: geo)
                        dualFindZone(geo: geo)
                    }
                    .frame(height: (geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom) * 0.14)

                    ppsrZone(geo: geo)
                        .frame(height: (geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom) * 0.22)

                    settingsAndTestingZone(geo: geo)
                        .frame(maxHeight: .infinity)

                    Spacer().frame(height: geo.safeAreaInsets.bottom + 4)
                }

                VStack {
                    Spacer()

                    HStack {
                        Spacer()
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.15))
                            .padding(.trailing, 16)
                    }
                    .padding(.bottom, geo.safeAreaInsets.bottom + 6)
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.12)) {
                animateIn = true
            }
        }
        .onDisappear {
            animateIn = false
        }
    }

    private func joeZone(geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .joe
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Color.clear

                LinearGradient(
                    colors: [.green.opacity(0.0), .green.opacity(0.15)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "suit.spade.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating.speed(0.4))
                        .shadow(color: .green.opacity(0.6), radius: 10)

                    Text("JOE\nFORTUNE")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineSpacing(2)
                        .shadow(color: .black.opacity(0.8), radius: 4)

                    Text("Login Testing")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.7))

                    HStack(spacing: 3) {
                        Text("ENTER")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.6))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.green.opacity(0.4))
                    }
                    .padding(.top, 2)
                }
                .padding(16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(x: animateIn ? 0 : -30)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .joe)
    }

    private func ignitionZone(geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .ignition
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Color.clear

                LinearGradient(
                    colors: [.orange.opacity(0.0), .orange.opacity(0.15)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse, options: .repeating.speed(0.4))
                        .shadow(color: .orange.opacity(0.6), radius: 10)

                    Text("IGNITION\nCASINO")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .lineSpacing(2)
                        .shadow(color: .black.opacity(0.8), radius: 4)

                    Text("Login Testing")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.7))

                    HStack(spacing: 3) {
                        Text("ENTER")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.6))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.orange.opacity(0.4))
                    }
                    .padding(.top, 2)
                }
                .padding(16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(x: animateIn ? 0 : 30)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .ignition)
    }

    private func ppsrZone(geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .ppsr
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [.blue.opacity(0.05), .cyan.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.cyan)
                            .shadow(color: .cyan.opacity(0.5), radius: 8)

                        Text("PPSR")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("VIN & Card Testing")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                    }
                    .padding(.leading, 20)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.cyan)
                            .shadow(color: .cyan.opacity(0.5), radius: 8)

                        Text("CHECK")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        HStack(spacing: 3) {
                            Text("ENTER")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.cyan.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.cyan.opacity(0.4))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(y: animateIn ? 0 : 30)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .ppsr)
    }

    private func settingsAndTestingZone(geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .settingsAndTesting
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.1, green: 0.1, blue: 0.15).opacity(0.4), Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.3)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape.2.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.purple.opacity(0.7))
                        }
                        .shadow(color: .blue.opacity(0.4), radius: 8)

                        Text("SETTINGS & TESTING")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("Super Test · IP Score · Nord Config · Debug")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.leading, 20)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Image(systemName: "shield.lefthalf.filled")
                            Image(systemName: "externaldrive.fill")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))

                        HStack(spacing: 3) {
                            Text("OPEN")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(y: animateIn ? 0 : 30)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .settingsAndTesting)
    }

    private func splitTestZone(geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .splitTest
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [.green.opacity(0.12), .orange.opacity(0.12)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "suit.spade.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.green)
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.4))
                            Image(systemName: "flame.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.orange)
                        }

                        Text("SPLIT TEST")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("Joe + Ignition Simultaneous")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.leading, 20)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Image(systemName: "rectangle.split.2x1.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                            )

                        HStack(spacing: 3) {
                            Text("LAUNCH")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(y: animateIn ? 0 : 20)
        .sensoryFeedback(.impact(weight: .heavy), trigger: activeMode == .splitTest)
    }



    private func dualFindZone(geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .dualFind
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [.purple.opacity(0.15), .indigo.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.purple)
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.indigo)
                        }
                        .shadow(color: .purple.opacity(0.5), radius: 8)

                        Text("DUAL FIND")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("Email × 3 Passwords")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.purple.opacity(0.7))

                        HStack(spacing: 3) {
                            Text("FIND")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.purple.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.purple.opacity(0.4))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .offset(x: animateIn ? 0 : 30)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .dualFind)
    }

    private var profileSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(NordKeyProfile.allCases, id: \.self) { profile in
                Button {
                    guard nordService.activeKeyProfile != profile else { return }
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                        nordService.switchProfile(profile)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: profile == .nick ? "person.fill" : "person.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(profile.rawValue.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                    }
                    .foregroundStyle(nordService.activeKeyProfile == profile ? .white : .white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Group {
                            if nordService.activeKeyProfile == profile {
                                Capsule()
                                    .fill(
                                        profile == .nick
                                            ? LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                                            : LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                                    )
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .sensoryFeedback(.impact(weight: .heavy), trigger: nordService.activeKeyProfile)
        .opacity(animateIn ? 1 : 0)
        .offset(y: animateIn ? 0 : -20)
    }
}

nonisolated enum ActiveAppMode: String, Sendable {
    case joe
    case ignition
    case ppsr
    case superTest
    case debugLog
    case flowRecorder
    case nordConfig
    case splitTest
    case vault
    case ipScoreTest
    case dualFind
    case settingsAndTesting
}

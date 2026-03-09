import SwiftUI

struct SplitTestView: View {
    @State private var vm = LoginViewModel()
    @State private var initialSetupDone: Bool = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            if isLandscape {
                HStack(spacing: 0) {
                    joeSplitPanel
                    splitDivider(isVertical: true)
                    ignitionSplitPanel
                }
            } else {
                VStack(spacing: 0) {
                    joeSplitPanel
                    splitDivider(isVertical: false)
                    ignitionSplitPanel
                }
            }
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(.dark)
        .onAppear {
            if !initialSetupDone {
                initialSetupDone = true
                vm.setSiteMode(.dual)
            }
        }
        .safeAreaInset(edge: .bottom) {
            splitControlBar
        }
        .withBatchAlerts(
            showBatchResult: $vm.showBatchResultPopup,
            batchResult: vm.lastBatchResult,
            isRunning: $vm.isRunning,
            onDismissBatch: { vm.showBatchResultPopup = false }
        )
    }

    private var joeSplitPanel: some View {
        VStack(spacing: 0) {
            splitPanelHeader(
                icon: "suit.spade.fill",
                title: "JOE FORTUNE",
                color: .green,
                urlCount: vm.urlRotation.joeURLs.filter(\.isEnabled).count,
                totalURLs: vm.urlRotation.joeURLs.count
            )

            ScrollView {
                LazyVStack(spacing: 8) {
                    splitStatsRow(site: .joe)

                    let joeAttempts = vm.attempts.filter { attempt in
                        attempt.logs.contains { $0.message.contains("[JOE]") } ||
                        (!attempt.logs.contains { $0.message.contains("[IGN]") } && !vm.dualSiteMode) ||
                        attemptIsForSite(attempt, site: .joefortune)
                    }.prefix(50)

                    if joeAttempts.isEmpty {
                        splitEmptyState(color: .green)
                    } else {
                        ForEach(Array(joeAttempts)) { attempt in
                            SplitSessionRow(attempt: attempt, accentColor: .green)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private var ignitionSplitPanel: some View {
        VStack(spacing: 0) {
            splitPanelHeader(
                icon: "flame.fill",
                title: "IGNITION",
                color: .orange,
                urlCount: vm.urlRotation.ignitionURLs.filter(\.isEnabled).count,
                totalURLs: vm.urlRotation.ignitionURLs.count
            )

            ScrollView {
                LazyVStack(spacing: 8) {
                    splitStatsRow(site: .ignition)

                    let ignAttempts = vm.attempts.filter { attempt in
                        attempt.logs.contains { $0.message.contains("[IGN]") } ||
                        attemptIsForSite(attempt, site: .ignition)
                    }.prefix(50)

                    if ignAttempts.isEmpty {
                        splitEmptyState(color: .orange)
                    } else {
                        ForEach(Array(ignAttempts)) { attempt in
                            SplitSessionRow(attempt: attempt, accentColor: .orange)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func splitPanelHeader(icon: String, title: String, color: Color, urlCount: Int, totalURLs: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: vm.isRunning)

            Text(title)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            Text("\(urlCount)/\(totalURLs)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.12))
                .clipShape(Capsule())

            if vm.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
    }

    private func splitDivider(isVertical: Bool) -> some View {
        Group {
            if isVertical {
                Rectangle()
                    .fill(LinearGradient(colors: [.green.opacity(0.4), .orange.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2)
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [.green.opacity(0.4), .orange.opacity(0.4)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
            }
        }
    }

    nonisolated enum SplitSite {
        case joe, ignition
    }

    private func splitStatsRow(site: SplitSite) -> some View {
        let color: Color = site == .joe ? .green : .orange
        let siteAttempts: [LoginAttempt]
        if site == .joe {
            siteAttempts = vm.attempts.filter { attempt in
                attempt.logs.contains { $0.message.contains("[JOE]") } ||
                attemptIsForSite(attempt, site: .joefortune)
            }
        } else {
            siteAttempts = vm.attempts.filter { attempt in
                attempt.logs.contains { $0.message.contains("[IGN]") } ||
                attemptIsForSite(attempt, site: .ignition)
            }
        }

        let working = siteAttempts.filter { $0.status == .completed }.count
        let failed = siteAttempts.filter { $0.status == .failed }.count
        let active = siteAttempts.filter { !$0.status.isTerminal }.count

        return HStack(spacing: 6) {
            SplitMiniStat(value: "\(working)", label: "OK", color: .green)
            SplitMiniStat(value: "\(failed)", label: "FAIL", color: .red)
            SplitMiniStat(value: "\(active)", label: "LIVE", color: color)
        }
    }

    private func splitEmptyState(color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1")
                .font(.title2)
                .foregroundStyle(color.opacity(0.3))
            Text("No sessions yet")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func attemptIsForSite(_ attempt: LoginAttempt, site: LoginTargetSite) -> Bool {
        guard let url = attempt.detectedURL else { return false }
        if site == .ignition {
            return url.contains("ignition")
        } else {
            return url.contains("joe") || url.contains("fortune")
        }
    }

    private var splitControlBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            HStack(spacing: 10) {
                MainMenuButton()

                if vm.isRunning {
                    HStack(spacing: 6) {
                        if vm.isPaused {
                            Button {
                                vm.resumeQueue()
                            } label: {
                                splitControlButton(icon: "play.fill", label: "RESUME", color: .green)
                            }
                        } else {
                            Button {
                                vm.pauseQueue()
                            } label: {
                                splitControlButton(icon: "pause.fill", label: "PAUSE", color: .orange)
                            }
                        }

                        Button {
                            vm.stopQueue()
                        } label: {
                            splitControlButton(icon: "stop.fill", label: "STOP", color: .red)
                        }
                        .disabled(vm.isStopping)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(vm.activeTestCount) active")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                        Text("\(vm.untestedCredentials.count) queued")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        vm.testAllUntested()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("SPLIT TEST ALL")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                    }
                    .disabled(vm.untestedCredentials.isEmpty)
                    .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(vm.credentials.count) total")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("\(vm.untestedCredentials.count) untested")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private func splitControlButton(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct SplitMiniStat: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(color.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }
}

struct SplitSessionRow: View {
    let attempt: LoginAttempt
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            if let snapshot = attempt.responseSnapshot {
                Color(.tertiarySystemFill)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(uiImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: attempt.status.icon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: !attempt.status.isTerminal)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(.rect(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attempt.credential.username)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(attempt.status.rawValue)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)

                    if !attempt.status.isTerminal {
                        ProgressView(value: attempt.status.progress)
                            .tint(accentColor)
                            .frame(width: 40)
                    }
                }
            }

            Spacer()

            Text(attempt.formattedDuration)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch attempt.status {
        case .completed: .green
        case .failed: .red
        case .queued: .secondary
        default: .cyan
        }
    }
}

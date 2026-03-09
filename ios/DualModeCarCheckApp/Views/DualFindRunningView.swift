import SwiftUI

struct DualFindRunningView: View {
    @Bindable var vm: DualFindViewModel

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

            ScrollView {
                VStack(spacing: 14) {
                    hitsSection

                    sessionGrid

                    logFeed
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            controlBar
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $vm.showLoginFound) {
            loginFoundSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.success, trigger: vm.hits.count)
    }

    // MARK: - Progress Header

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.progressText)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)

                    Text("\(vm.hits.count) hit\(vm.hits.count == 1 ? "" : "s") · \(vm.disabledEmails.count) disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                if vm.isPaused {
                    Text("PAUSED")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.yellow.opacity(0.15))
                        .clipShape(Capsule())
                } else {
                    Text("RUNNING")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            ProgressView(value: vm.progressFraction)
                .tint(.purple)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Hits

    @ViewBuilder
    private var hitsSection: some View {
        if !vm.hits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Hits Found", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)

                ForEach(vm.hits) { hit in
                    HStack(spacing: 10) {
                        Image(systemName: hit.platform.contains("Joe") ? "suit.spade.fill" : "flame.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(hit.platform.contains("Joe") ? .green : .orange)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.email)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                            Text(hit.password)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }

                        Spacer()

                        Text(hit.platform.contains("Joe") ? "JOE" : "IGN")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(10)
                    .background(.green.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    // MARK: - Session Grid

    private var sessionGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sessions", systemImage: "rectangle.stack")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(vm.sessions, id: \.id) { session in
                    sessionCard(session)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func sessionCard(_ session: DualFindSessionInfo) -> some View {
        let isJoe = session.platform.contains("Joe")
        let accent: Color = isJoe ? .green : .orange

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: isJoe ? "suit.spade.fill" : "flame.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent)

                Text(isJoe ? "JOE" : "IGN")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(accent)

                Text("#\(session.index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))

                Spacer()

                Circle()
                    .fill(session.isActive ? .green : .gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            if !session.currentEmail.isEmpty {
                Text(session.currentEmail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(session.status)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor(session.status))
        }
        .padding(10)
        .background(accent.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "HIT!": .green
        case "Disabled": .red
        case "Testing", "Rebuilding": .yellow
        case "No Acc", "Done": .white.opacity(0.3)
        default: .white.opacity(0.4)
        }
    }

    // MARK: - Log Feed

    private var logFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Log", systemImage: "text.alignleft")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(vm.logs.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(vm.logs.prefix(200)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.formattedTime)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))

                        Text(entry.message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(logColor(entry.level))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .white.opacity(0.5)
        case .success: .green
        case .warning: .yellow
        case .error: .red
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            if vm.isPaused {
                Button {
                    vm.resumeFromPause()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.green)
                        .clipShape(.rect(cornerRadius: 10))
                }
            } else {
                Button {
                    vm.pauseRun()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.yellow.opacity(0.8))
                        .clipShape(.rect(cornerRadius: 10))
                }
            }

            Button {
                vm.stopRun()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red.opacity(0.8))
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Login Found Sheet

    private var loginFoundSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: vm.latestHit?.id)

            Text("LOGIN FOUND")
                .font(.system(size: 24, weight: .black, design: .monospaced))
                .foregroundStyle(.green)

            if let hit = vm.latestHit {
                VStack(spacing: 8) {
                    HStack {
                        Text("Email")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(hit.email)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    HStack {
                        Text("Password")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(hit.password)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    HStack {
                        Text("Platform")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(hit.platform)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(hit.platform.contains("Joe") ? .green : .orange)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }

            Text("Run is paused. Tap Resume to continue testing.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                vm.showLoginFound = false
                vm.resumeFromPause()
            } label: {
                Text("Continue Testing")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.purple)
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
        .padding(24)
    }
}

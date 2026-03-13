import SwiftUI

struct TestDebugResultsView: View {
    @Bindable var vm: TestDebugViewModel
    @State private var selectedTab: ResultsTab = .grid

    nonisolated enum ResultsTab: String, CaseIterable, Sendable {
        case grid = "Grid"
        case ranked = "Ranked"
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            
            switch selectedTab {
            case .grid:
                screenshotGrid
            case .ranked:
                rankedList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.reset()
                } label: {
                    Label("New Test", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var tabPicker: some View {
        VStack(spacing: 12) {
            summaryBar

            HStack(spacing: 0) {
                ForEach(ResultsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(selectedTab == tab ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                Group {
                                    if selectedTab == tab {
                                        Capsule()
                                            .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            summaryPill(value: "\(vm.sessions.count)", label: "Total", color: .primary)
            summaryPill(value: "\(vm.successCount)", label: "Success", color: .green)
            summaryPill(value: "\(vm.failedCount)", label: "Failed", color: .red)
            summaryPill(value: "\(vm.unsureCount)", label: "Unsure", color: .yellow)
        }
        .padding(.horizontal, 16)
    }

    private func summaryPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var screenshotGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                ForEach(vm.sessions) { session in
                    screenshotCard(session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func screenshotCard(_ session: TestDebugSession) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color(.tertiarySystemGroupedBackground)
                    .frame(height: 140)

                if let img = session.finalScreenshot {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: session.status.icon)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(statusColor(session.status))
                        Text(session.status.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 140)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text("#\(session.index)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6))
                    .clipShape(.rect(cornerRadius: 6))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(statusColor(session.status))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.differentiator)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(session.status.rawValue)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(session.status))
                    Spacer()
                    Text(session.formattedDuration)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var rankedList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let winner = vm.winningSession {
                    winnerCard(winner)
                }

                ForEach(vm.rankedSessions) { session in
                    rankedRow(session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func winnerCard(_ session: TestDebugSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.yellow)
                Text("OPTIMAL SETTINGS")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(session.formattedDuration)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text(session.differentiator)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.6, green: 0.5, blue: 0.1), Color(red: 0.4, green: 0.3, blue: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(.rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .yellow.opacity(0.15), radius: 12, y: 4)
    }

    private func rankedRow(_ session: TestDebugSession) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor(session.status).opacity(0.15))
                    .frame(width: 36, height: 36)
                Text("\(session.index)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(statusColor(session.status))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.differentiator)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: session.status.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusColor(session.status))
                    Text(session.status.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(session.status))

                    if let err = session.errorMessage {
                        Text(err)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(session.formattedDuration)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func statusColor(_ status: TestDebugSessionStatus) -> Color {
        switch status {
        case .queued: .secondary
        case .running: .blue
        case .success: .green
        case .failed, .connectionFailure: .red
        case .unsure: .yellow
        case .timeout: .orange
        }
    }
}

import SwiftUI

struct LoginSessionMonitorContentView: View {
    let vm: LoginViewModel
    @State private var selectedAttempt: LoginAttempt?
    @State private var filterStatus: FilterOption = .all
    @State private var viewMode: ViewMode = .list

    nonisolated enum FilterOption: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case active = "Active"
        case completed = "Passed"
        case failed = "Failed"
        var id: String { rawValue }
    }

    private var filteredAttempts: [LoginAttempt] {
        switch filterStatus {
        case .all: vm.attempts
        case .active: vm.attempts.filter { !$0.status.isTerminal }
        case .completed: vm.completedAttempts
        case .failed: vm.failedAttempts
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if filteredAttempts.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "rectangle.stack", description: Text("Test credentials to see sessions here."))
            } else if viewMode == .tile {
                sessionTileGrid
            } else {
                sessionListView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ViewModeToggle(mode: $viewMode, accentColor: .green)
            }
        }
        .sheet(item: $selectedAttempt) { attempt in
            LoginSessionDetailSheet(attempt: attempt)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterOption.allCases) { option in
                    LoginSessionFilterChip(title: option.rawValue, count: countFor(option), isSelected: filterStatus == option) {
                        withAnimation(.snappy) { filterStatus = option }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private func countFor(_ option: FilterOption) -> Int {
        switch option {
        case .all: vm.attempts.count
        case .active: vm.activeAttempts.count
        case .completed: vm.completedAttempts.count
        case .failed: vm.failedAttempts.count
        }
    }

    private var sessionListView: some View {
        List(filteredAttempts) { attempt in
            Button { selectedAttempt = attempt } label: { LoginSessionRow(attempt: attempt) }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
    }

    private var sessionTileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(filteredAttempts) { attempt in
                    Button { selectedAttempt = attempt } label: {
                        let latestScreenshot = attempt.responseSnapshot ?? vm.screenshotsForAttempt(attempt).first?.image
                        ScreenshotTileView(
                            screenshot: latestScreenshot,
                            title: attempt.credential.username,
                            subtitle: "S\(attempt.sessionIndex) · \(attempt.formattedDuration)",
                            statusColor: attemptStatusColor(attempt.status),
                            statusText: attempt.status.rawValue,
                            badge: attempt.hasScreenshot ? "📷" : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func attemptStatusColor(_ status: LoginAttemptStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .queued: .secondary
        default: .green
        }
    }
}

struct LoginSessionFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if count > 0 {
                    Text("\(count)").font(.system(.caption2, design: .monospaced, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(isSelected ? Color.green : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LoginSessionRow: View {
    let attempt: LoginAttempt

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let snapshot = attempt.responseSnapshot {
                    Color.clear.frame(width: 48, height: 48)
                        .overlay { Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                        .clipShape(.rect(cornerRadius: 6))
                } else {
                    Image(systemName: attempt.status.icon)
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: !attempt.status.isTerminal)
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(attempt.credential.username)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(1)
                    if let snippet = attempt.responseSnippet {
                        Text(snippet.prefix(60))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary).lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("S\(attempt.sessionIndex)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(.rect(cornerRadius: 4)).foregroundStyle(.primary)
                    if attempt.hasScreenshot {
                        Image(systemName: "camera.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if !attempt.status.isTerminal {
                ProgressView(value: attempt.status.progress).tint(.green)
            }

            HStack {
                Text(attempt.status.rawValue).font(.caption).foregroundStyle(statusColor)
                Spacer()
                Label(attempt.formattedDuration, systemImage: "timer")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch attempt.status {
        case .completed: .green
        case .failed: .red
        case .queued: .secondary
        default: .green
        }
    }
}

struct LoginSessionDetailSheet: View {
    let attempt: LoginAttempt
    @State private var showFullScreenshot: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = attempt.responseSnapshot {
                    Section("Screenshot") {
                        Button { showFullScreenshot = true } label: {
                            Image(uiImage: snapshot)
                                .resizable().aspectRatio(contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 8))
                                .frame(maxHeight: 200)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                Section("Details") {
                    LabeledContent("Username") {
                        Text(attempt.credential.username).font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: attempt.status.icon)
                            Text(attempt.status.rawValue)
                        }
                        .foregroundStyle(attempt.status == .completed ? .green : attempt.status == .failed ? .red : .blue)
                    }
                    LabeledContent("Session", value: "S\(attempt.sessionIndex)")
                    LabeledContent("Duration", value: attempt.formattedDuration)
                    if let url = attempt.detectedURL {
                        LabeledContent("Final URL") {
                            Text(url).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }

                if let error = attempt.errorMessage {
                    Section("Error") {
                        Text(error).font(.system(.body, design: .monospaced)).foregroundStyle(.red)
                    }
                }

                if let snippet = attempt.responseSnippet {
                    Section("Response Preview") {
                        Text(snippet)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }

                Section("Execution Log") {
                    if attempt.logs.isEmpty {
                        Text("No log entries").foregroundStyle(.secondary)
                    } else {
                        ForEach(attempt.logs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTime).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 80, alignment: .leading)
                                Text(entry.level.rawValue).font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(logColor(entry.level)).frame(width: 36)
                                Text(entry.message).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary)
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Session Detail").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showFullScreenshot) {
                if let snapshot = attempt.responseSnapshot {
                    FullScreenshotView(image: snapshot)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level { case .info: .blue; case .success: .green; case .warning: .orange; case .error: .red }
    }
}

struct FullScreenshotView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .background(.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

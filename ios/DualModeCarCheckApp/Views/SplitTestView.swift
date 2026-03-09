import SwiftUI

struct SplitTestView: View {
    @State private var vm = LoginViewModel()
    @State private var initialSetupDone: Bool = false
    @State private var selectedJoeURL: String = ""
    @State private var selectedIgnitionURL: String = ""
    @State private var showURLPicker: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var showAutomationSettings: Bool = false

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
        .safeAreaInset(edge: .top) {
            splitTopBar
        }
        .safeAreaInset(edge: .bottom) {
            splitControlBar
        }
        .sheet(isPresented: $showURLPicker) {
            urlPickerSheet
        }
        .sheet(isPresented: $showImportSheet) {
            splitImportSheet
        }
        .sheet(isPresented: $showAutomationSettings) {
            NavigationStack {
                AutomationSettingsView(vm: vm)
                    .navigationTitle("Automation Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showAutomationSettings = false }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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

    private var splitTopBar: some View {
        HStack(spacing: 8) {
            Button {
                showURLPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                    Text("URLs")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.cyan.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            if !selectedJoeURL.isEmpty {
                Text(URL(string: selectedJoeURL)?.host ?? "")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.7))
                    .lineLimit(1)
            }

            Button {
                showImportSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                    Text("IMPORT")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showAutomationSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.purple.opacity(0.9))
                    .frame(width: 32, height: 32)
                    .background(.purple.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var urlPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    let joeURLs = vm.urlRotation.joeURLs
                    if joeURLs.isEmpty {
                        Text("No Joe Fortune URLs configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(joeURLs) { urlEntry in
                            Button {
                                selectedJoeURL = urlEntry.urlString
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: selectedJoeURL == urlEntry.urlString ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedJoeURL == urlEntry.urlString ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(urlEntry.host)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        if urlEntry.totalAttempts > 0 {
                                            Text("\(urlEntry.formattedSuccessRate) success · \(urlEntry.formattedAvgResponse) avg")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Circle()
                                        .fill(urlEntry.isEnabled ? .green : .red)
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                    }
                } header: {
                    Label("Joe Fortune URLs", systemImage: "suit.spade.fill")
                }

                Section {
                    let ignURLs = vm.urlRotation.ignitionURLs
                    if ignURLs.isEmpty {
                        Text("No Ignition URLs configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ignURLs) { urlEntry in
                            Button {
                                selectedIgnitionURL = urlEntry.urlString
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: selectedIgnitionURL == urlEntry.urlString ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIgnitionURL == urlEntry.urlString ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(urlEntry.host)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        if urlEntry.totalAttempts > 0 {
                                            Text("\(urlEntry.formattedSuccessRate) success · \(urlEntry.formattedAvgResponse) avg")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Circle()
                                        .fill(urlEntry.isEnabled ? .green : .red)
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                    }
                } header: {
                    Label("Ignition URLs", systemImage: "flame.fill")
                }

                Section {
                    Button {
                        selectedJoeURL = ""
                        selectedIgnitionURL = ""
                    } label: {
                        Label("Use Auto-Rotation (Default)", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Select specific URLs or leave on auto-rotation for best performance.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("URL Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showURLPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var splitImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste credentials (email:password per line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $importText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10))

                Button {
                    vm.smartImportCredentials(importText)
                    importText = ""
                    showImportSheet = false
                } label: {
                    Text("Import")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing))
                        .foregroundStyle(.black)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .navigationTitle("Import Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showImportSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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

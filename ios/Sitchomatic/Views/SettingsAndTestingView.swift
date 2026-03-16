import SwiftUI

struct SettingsAndTestingView: View {
    @State private var showCopiedToast: Bool = false
    @State private var shareFileURL: URL?
    @State private var nordService = NordVPNService.shared
    @AppStorage("introVideoEnabled") private var introVideoEnabled: Bool = false
    @AppStorage("activeAppMode") private var activeModeRaw: String = ""
    private let proxyService = ProxyRotationService.shared

    var body: some View {
        NavigationStack {
            List {
                testingToolsSection
                networkAndVPNSection
                debugAndDiagnosticsSection
                dataManagementSection
                appSettingsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings & Testing")
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("Copied to clipboard")
                        .font(.subheadline.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.green.gradient, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
            .sheet(isPresented: Binding(
                get: { shareFileURL != nil },
                set: { if !$0 { shareFileURL = nil } }
            )) {
                if let url = shareFileURL {
                    ShareSheetView(items: [url])
                }
            }
        }
        .withMainMenuButton()
        .preferredColorScheme(.dark)
    }

    private var testingToolsSection: some View {
        Section {
            NavigationLink {
                SuperTestView()
            } label: {
                settingsRow(
                    icon: "bolt.horizontal.circle.fill",
                    title: "Super Test",
                    subtitle: "Full infrastructure validation",
                    color: .purple
                )
            }

            NavigationLink {
                IPScoreTestView()
            } label: {
                settingsRow(
                    icon: "network.badge.shield.half.filled",
                    title: "IP Score Test",
                    subtitle: "8x concurrent IP quality analysis",
                    color: .indigo
                )
            }
        } header: {
            Label("Testing Tools", systemImage: "flask.fill")
        } footer: {
            Text("Run full infrastructure tests and IP quality checks.")
        }
    }

    private var networkAndVPNSection: some View {
        Section {
            NavigationLink {
                DeviceNetworkSettingsView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device Network Settings").font(.subheadline.bold())
                        Text("Proxy, VPN, WireGuard, DNS — all modes")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(proxyService.unifiedConnectionMode.label)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12)).clipShape(Capsule())
                }
            }

            NavigationLink {
                NordLynxConfigView()
            } label: {
                settingsRow(
                    icon: "shield.checkered",
                    title: "Nord Config",
                    subtitle: "WireGuard & OpenVPN generation",
                    color: Color(red: 0.0, green: 0.78, blue: 1.0)
                )
            }

            NavigationLink {
                NetworkRepairView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.body)
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Repair Network").font(.subheadline.bold())
                        Text("Full restart of all network protocols")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if NetworkRepairService.shared.isRepairing {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let result = NetworkRepairService.shared.lastRepairResult {
                        Image(systemName: result.overallSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.overallSuccess ? .green : .red)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Label("Network & VPN", systemImage: "lock.shield.fill")
        } footer: {
            Text("Network configs are device-wide. Changes apply to Joe, Ignition & PPSR.")
        }
    }

    private var debugAndDiagnosticsSection: some View {
        Group {
            Section {
                NavigationLink {
                    DebugLogView()
                } label: {
                    settingsRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Full Debug Log",
                        subtitle: "View all debug entries",
                        color: .purple
                    )
                }

                NavigationLink {
                    SettingsConsoleView()
                } label: {
                    settingsRow(
                        icon: "terminal.fill",
                        title: "Console",
                        subtitle: "Live log output",
                        color: .green
                    )
                }

                NavigationLink {
                    NoticesView()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.body)
                                .foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notices").font(.subheadline.bold())
                            Text("Failure log & auto-retry history")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let count = NoticesService.shared.unreadCount
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                }
            } header: {
                Label("Debug & Diagnostics", systemImage: "stethoscope")
            }

            Section {
                Button {
                    let text = DebugLogger.shared.exportDiagnosticReport(
                        credentials: [],
                        automationSettings: AutomationSettings()
                    )
                    UIPasteboard.general.string = text
                    withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
                    Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
                } label: {
                    settingsRow(
                        icon: "stethoscope",
                        title: "Export Diagnostic Report",
                        subtitle: "Copy full report to clipboard",
                        color: .red
                    )
                }

                Button {
                    shareFileURL = DebugLogger.shared.exportLogToFile()
                } label: {
                    settingsRow(
                        icon: "square.and.arrow.up",
                        title: "Share Debug Log File",
                        subtitle: "Export full log as shareable .txt file",
                        color: .purple
                    )
                }

                Button {
                    shareFileURL = DebugLogger.shared.exportDiagnosticReportToFile(credentials: [], automationSettings: AutomationSettings())
                } label: {
                    settingsRow(
                        icon: "stethoscope.circle",
                        title: "Share Diagnostic File",
                        subtitle: "Export diagnostic report as shareable .txt",
                        color: .indigo
                    )
                }
            } header: {
                Label("Diagnostic Reports", systemImage: "doc.badge.gearshape")
            }
        }
    }

    private var dataManagementSection: some View {
        Section {
            NavigationLink {
                ConsolidatedImportExportView()
            } label: {
                settingsRow(
                    icon: "arrow.up.arrow.down.circle.fill",
                    title: "Import / Export",
                    subtitle: "Full backup & restore of all data",
                    color: .blue
                )
            }

            NavigationLink {
                StorageFileBrowserView()
            } label: {
                settingsRow(
                    icon: "externaldrive.fill",
                    title: "Vault",
                    subtitle: "Browse persistent file storage",
                    color: .teal
                )
            }
        } header: {
            Label("Data Management", systemImage: "tray.2.fill")
        } footer: {
            Text("Comprehensive backup covering all settings, credentials, cards, URLs, proxies, VPN, DNS, blacklist, emails, recorded flows, and button configs.")
        }
    }

    private var appSettingsSection: some View {
        Group {
            Section {
                Picker(selection: Binding(
                    get: { AppAppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance_mode") ?? "System") ?? .system },
                    set: { UserDefaults.standard.set($0.rawValue, forKey: "appearance_mode") }
                )) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                } label: {
                    HStack(spacing: 10) { Image(systemName: "paintbrush.fill").foregroundStyle(.purple); Text("Appearance") }
                }

                Toggle(isOn: $introVideoEnabled) {
                    HStack(spacing: 10) {
                        Image(systemName: "film.fill").foregroundStyle(.pink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Intro Video").font(.body)
                            Text("Play intro video on app launch").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.pink)
            } header: {
                Label("App Settings", systemImage: "gearshape.fill")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                LabeledContent("Profile") {
                    Text(nordService.hasSelectedProfile ? nordService.activeKeyProfile.rawValue : "Not Selected")
                        .foregroundStyle(nordService.activeKeyProfile == .nick ? .blue : .purple)
                }
                LabeledContent("Engine", value: "WKWebView Live")
                LabeledContent("Storage", value: "Unlimited · Local + iCloud")
                LabeledContent("Connection") {
                    Text(proxyService.unifiedConnectionMode.label)
                        .foregroundStyle(proxyService.unifiedConnectionMode == .proxy ? .blue : .cyan)
                }
                LabeledContent("Mode") { Text("Live — Real Transactions").foregroundStyle(.orange) }
            } header: {
                Text("About")
            }
        }
    }

    private func settingsRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsConsoleView: View {
    @State private var logs: [DebugLogEntry] = []

    var body: some View {
        List {
            if logs.isEmpty {
                Text("No log entries").foregroundStyle(.tertiary)
            } else {
                ForEach(logs) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.formattedTime)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 80, alignment: .leading)
                        Text(entry.level.emoji)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .frame(width: 20)
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Console")
        .onAppear {
            logs = Array(DebugLogger.shared.entries.suffix(100).reversed())
        }
        .refreshable {
            logs = Array(DebugLogger.shared.entries.suffix(100).reversed())
        }
    }
}

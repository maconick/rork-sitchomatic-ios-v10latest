import SwiftUI

struct LoginMoreMenuView: View {
    let vm: LoginViewModel
    @State private var showCopiedToast: Bool = false
    @State private var shareFileURL: URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
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
                            Text(ProxyRotationService.shared.unifiedConnectionMode.label)
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12)).clipShape(Capsule())
                        }
                    }

                    NavigationLink {
                        LoginNetworkSettingsView(vm: vm)
                    } label: {
                        moreRow(icon: "arrow.triangle.2.circlepath", title: "URLs & Endpoint", subtitle: "URL rotation, validation & connectivity", color: .green)
                    }

                    NavigationLink {
                        LoginSettingsContentView(vm: vm)
                    } label: {
                        moreRow(icon: "gearshape.fill", title: "Advanced Settings", subtitle: "Automation, stealth, debug & more", color: .secondary)
                    }

                    NavigationLink {
                        AutomationSettingsView(vm: vm)
                    } label: {
                        moreRow(icon: "slider.horizontal.3", title: "Automation Config", subtitle: "Every facet of automation flow control", color: .teal)
                    }
                }

                Section {
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
                } footer: {
                    Text("Unusual failures are logged here. Auto-retry handles them automatically.")
                }

                Section("Login Button Debugger") {
                    NavigationLink {
                        DebugLoginButtonView(vm: vm)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "target")
                                .font(.title3).foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Debug Login Button").font(.subheadline.bold())
                                Text("\(DebugLoginButtonService.shared.configs.count) saved configs")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if DebugLoginButtonService.shared.configs.values.contains(where: { $0.userConfirmed }) {
                                Text("ACTIVE")
                                    .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.12)).clipShape(Capsule())
                            }
                        }
                    }
                }

                Section("Flow Recorder") {
                    NavigationLink {
                        FlowRecorderView()
                    } label: {
                        moreRow(icon: "record.circle", title: "Record Login Flow", subtitle: "Record & replay human login patterns", color: .red)
                    }

                    NavigationLink {
                        SavedFlowsView(vm: FlowRecorderViewModel())
                    } label: {
                        let flowCount = FlowPersistenceService.shared.loadFlows().count
                        HStack(spacing: 12) {
                            Image(systemName: "tray.full.fill").font(.title3).foregroundStyle(.indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Saved Flows").font(.subheadline.bold())
                                Text("\(flowCount) recorded login patterns").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Account Tools") {
                    NavigationLink {
                        CheckDisabledAccountsView(vm: vm)
                    } label: {
                        moreRow(icon: "magnifyingglass.circle.fill", title: "Check Disabled Accounts", subtitle: "Fast forgot-password check", color: .orange)
                    }

                    NavigationLink {
                        TempDisabledAccountsView(vm: vm)
                    } label: {
                        moreRow(icon: "clock.badge.exclamationmark", title: "Temp Disabled Accounts", subtitle: "\(vm.tempDisabledCredentials.count) accounts", color: .orange)
                    }
                }

                Section("Data") {
                    NavigationLink {
                        BlacklistView(vm: vm)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised.slash.fill")
                                .font(.title3).foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Blacklist").font(.subheadline.bold())
                                Text("\(vm.blacklistService.blacklistedEmails.count) blacklisted").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.blacklistService.autoExcludeBlacklist {
                                Text("AUTO")
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.red.opacity(0.12)).clipShape(Capsule())
                            }
                        }
                    }

                    NavigationLink {
                        CredentialExportView(vm: vm)
                    } label: {
                        moreRow(icon: "square.and.arrow.up.fill", title: "Export Credentials", subtitle: "Text or CSV by category", color: .blue)
                    }
                }

                Section("Diagnostic Report") {
                    Button {
                        let text = DebugLogger.shared.exportDiagnosticReport(
                            credentials: vm.credentials,
                            automationSettings: vm.automationSettings
                        )
                        UIPasteboard.general.string = text
                        vm.log("Copied diagnostic report to clipboard (\(text.count) chars)", level: .success)
                        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
                        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
                    } label: {
                        moreRow(icon: "stethoscope", title: "Export Diagnostic Report", subtitle: "Full report for Rork Max error analysis", color: .red)
                    }

                    Button {
                        shareFileURL = DebugLogger.shared.exportLogToFile()
                    } label: {
                        moreRow(icon: "square.and.arrow.up", title: "Share Debug Log File", subtitle: "Export full log as shareable .txt file", color: .purple)
                    }

                    Button {
                        shareFileURL = DebugLogger.shared.exportDiagnosticReportToFile(credentials: vm.credentials, automationSettings: vm.automationSettings)
                    } label: {
                        moreRow(icon: "stethoscope.circle", title: "Share Diagnostic File", subtitle: "Export diagnostic report as shareable .txt", color: .indigo)
                    }
                }

                Section("Import / Export") {
                    NavigationLink {
                        ConsolidatedImportExportView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.title3).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import / Export").font(.subheadline.bold())
                                Text("Full backup & restore of all data").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if vm.debugMode {
                    Section("Debug") {
                        NavigationLink {
                            LoginDebugScreenshotsView(vm: vm)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "ladybug.fill")
                                    .font(.title3).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Debug Screenshots").font(.subheadline.bold())
                                    Text("\(vm.debugScreenshots.count) screenshots captured").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !vm.debugScreenshots.isEmpty {
                                    let passCount = vm.debugScreenshots.filter({ $0.effectiveResult == .markedPass }).count
                                    let failCount = vm.debugScreenshots.filter({ $0.effectiveResult == .markedFail }).count
                                    HStack(spacing: 4) {
                                        if passCount > 0 {
                                            Text("\(passCount)").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.green)
                                        }
                                        if failCount > 0 {
                                            Text("\(failCount)").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Debug Log") {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.title3).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Full Debug Log").font(.subheadline.bold())
                                Text("View debug entries")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Section("Console") {
                    if vm.globalLogs.isEmpty {
                        Text("No log entries").foregroundStyle(.tertiary)
                    } else {
                        ForEach(vm.globalLogs.prefix(50)) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTime)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 80, alignment: .leading)
                                Text(entry.level.rawValue)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(moreLogColor(entry.level))
                                    .frame(width: 36)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

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
        .navigationTitle("More")
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ShareSheetView(items: [url])
            }
        }
    }

    private func moreRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func moreLogColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

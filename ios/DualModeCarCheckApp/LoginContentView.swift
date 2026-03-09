import SwiftUI
import UniformTypeIdentifiers

struct LoginContentView: View {
    let initialMode: ActiveAppMode
    @State private var vm = LoginViewModel()
    @State private var initialModeApplied: Bool = false

    private var accentColor: Color {
        vm.isIgnitionMode ? .orange : .green
    }

    private var loginSettingsHash: String {
        "\(vm.appearanceMode.rawValue)-\(vm.debugMode)-\(vm.maxConcurrency)-\(vm.stealthEnabled)-\(vm.targetSite.rawValue)-\(vm.autoRetryEnabled)-\(vm.autoRetryMaxAttempts)"
    }

    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: vm.isIgnitionMode ? "flame.fill" : "bolt.shield.fill") {
                NavigationStack {
                    LoginDashboardContentView(vm: vm)
                }
                .withMainMenuButton()
            }

            Tab("Credentials", systemImage: "person.text.rectangle") {
                NavigationStack {
                    LoginCredentialsListView(vm: vm)
                        .navigationDestination(for: String.self) { credId in
                            if let cred = vm.credentials.first(where: { $0.id == credId }) {
                                LoginCredentialDetailView(credential: cred, vm: vm)
                            }
                        }
                }
                .withMainMenuButton()
            }

            Tab("Working", systemImage: "checkmark.shield.fill") {
                NavigationStack {
                    LoginWorkingListView(vm: vm)
                }
                .withMainMenuButton()
            }

            Tab("Sessions", systemImage: "rectangle.stack") {
                NavigationStack {
                    LoginSessionMonitorContentView(vm: vm)
                }
                .withMainMenuButton()
            }

            Tab("More", systemImage: "ellipsis.circle") {
                NavigationStack {
                    LoginMoreMenuView(vm: vm)
                }
                .withMainMenuButton()
            }
        }
        .tint(accentColor)
        .preferredColorScheme(vm.effectiveColorScheme)
        .onAppear {
            if !initialModeApplied {
                initialModeApplied = true
                switch initialMode {
                case .joe: vm.setSiteMode(.joe)
                case .ignition: vm.setSiteMode(.ignition)
                case .ppsr, .superTest, .debugLog, .flowRecorder, .nordConfig, .splitTest, .vault, .ipScoreTest, .dualFind: break
                }
            }
        }
        .onChange(of: vm.credentials.count) { _, _ in
            vm.persistCredentials()
        }
        .onChange(of: loginSettingsHash) { _, _ in
            vm.persistSettings()
        }
        .withBatchAlerts(
            showBatchResult: $vm.showBatchResultPopup,
            batchResult: vm.lastBatchResult,
            isRunning: $vm.isRunning,
            onDismissBatch: { vm.showBatchResultPopup = false }
        )
    }
}

import SwiftUI

@main
struct DualModeCarCheckAppApp: App {
    @AppStorage("activeAppMode") private var activeModeRaw: String = ""
    @AppStorage("introVideoEnabled") private var introVideoEnabled: Bool = false
    @State private var introFinished: Bool = false
    @State private var nordInitialized: Bool = false

    private var activeMode: ActiveAppMode? {
        ActiveAppMode(rawValue: activeModeRaw)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if introVideoEnabled && !introFinished {
                    IntroVideoView(isFinished: $introFinished)
                        .transition(.opacity)
                } else if let mode = activeMode {
                    Group {
                        switch mode {
                        case .joe:
                            LoginContentView(initialMode: .joe)
                        case .ignition:
                            LoginContentView(initialMode: .ignition)
                        case .ppsr:
                            ContentView()
                        case .superTest:
                            SuperTestContainerView()
                        case .debugLog:
                            NavigationStack {
                                DebugLogView()
                            }
                            .withMainMenuButton()
                            .preferredColorScheme(.dark)
                        case .flowRecorder:
                            NavigationStack {
                                FlowRecorderView()
                            }
                            .withMainMenuButton()
                            .preferredColorScheme(.dark)
                        case .nordConfig:
                            NordLynxConfigView()
                        case .splitTest:
                            DualWebStackView()
                        case .vault:
                            NavigationStack {
                                StorageFileBrowserView()
                            }
                            .withMainMenuButton()
                            .preferredColorScheme(.dark)
                        case .ipScoreTest:
                            IPScoreTestView()
                        case .dualFind:
                            DualFindContainerView()
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                } else {
                    MainMenuView(activeMode: Binding(
                        get: { activeMode },
                        set: { newMode in
                            if let m = newMode {
                                activeModeRaw = m.rawValue
                            } else {
                                activeModeRaw = ""
                            }
                        }
                    ))
                    .transition(.opacity)
                }
            }
            .task {
                if !nordInitialized {
                    nordInitialized = true
                    let vault = PersistentFileStorageService.shared
                    let didRestore = vault.restoreIfNeeded()
                    if didRestore {
                        DebugLogger.shared.log("App launched — restored state from vault", category: .persistence, level: .success)
                    }
                    DefaultSettingsService.shared.applyDefaultsIfNeeded()
                    let nord = NordVPNService.shared
                    if !nord.hasAccessKey {
                        nord.setAccessKey(NordVPNKeyStore.defaultNickKey)
                    }
                    if nord.isTokenExpired {
                        nord.lastError = "NordVPN access token needs to be refreshed before fetching a private key."
                    }
                    vault.saveFullState()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                PersistentFileStorageService.shared.forceSave()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                PersistentFileStorageService.shared.forceSave()
            }
        }
    }
}

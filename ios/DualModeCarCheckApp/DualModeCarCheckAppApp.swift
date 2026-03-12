import SwiftUI

@main
struct DualModeCarCheckAppApp: App {
    @AppStorage("activeAppMode") private var activeModeRaw: String = ""
    @AppStorage("introVideoEnabled") private var introVideoEnabled: Bool = false
    @State private var introFinished: Bool = false
    @State private var nordInitialized: Bool = false
    @State private var nordService = NordVPNService.shared

    private var activeMode: ActiveAppMode? {
        ActiveAppMode(rawValue: activeModeRaw)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if introVideoEnabled && !introFinished {
                    IntroVideoView(isFinished: $introFinished)
                        .transition(.opacity)
                } else if !nordService.hasSelectedProfile {
                    MainMenuView(
                        activeMode: Binding(
                            get: { activeMode },
                            set: { newMode in
                                if let m = newMode {
                                    activeModeRaw = m.rawValue
                                } else {
                                    activeModeRaw = ""
                                }
                            }
                        ),
                        requiresProfileSelection: true
                    )
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
                        case .settingsAndTesting:
                            SettingsAndTestingView()
                        case .proxyManager:
                            ProxyManagerView()
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

                    let monitor = MemoryPressureMonitor.shared
                    monitor.register()
                    monitor.onMemoryWarning {
                        DebugLogger.shared.handleMemoryPressure()
                        WebViewPool.shared.handleMemoryPressure()
                        ScreenshotCacheService.shared.setMaxCacheCounts(memory: 20, disk: 300)
                    }

                    let vault = PersistentFileStorageService.shared
                    let didRestore = vault.restoreIfNeeded()
                    if didRestore {
                        DebugLogger.shared.log("App launched — restored state from vault", category: .persistence, level: .success)
                    }
                    DefaultSettingsService.shared.applyDefaultsIfNeeded()
                    let nord = nordService
                    await nord.ensureProfileNetworkPoolsReady()
                    if !nord.hasSelectedProfile {
                        activeModeRaw = ""
                    }
                    if nord.isTokenExpired {
                        nord.lastError = "NordVPN access token needs to be refreshed before fetching a private key."
                    }
                    vault.saveFullState()

                    if nord.hasSelectedProfile {
                        await nord.autoPopulateConfigs(forceRefresh: false)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                PersistentFileStorageService.shared.forceSave()
                DebugLogger.shared.persistLatestLog()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                PersistentFileStorageService.shared.forceSave()
                DebugLogger.shared.persistLatestLog()
            }
        }
    }
}

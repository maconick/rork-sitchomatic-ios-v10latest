import SwiftUI

@main
struct SitchomaticApp: App {
    @AppStorage("activeAppMode") private var activeModeRaw: String = ""
    @AppStorage("introVideoEnabled") private var introVideoEnabled: Bool = false
    @State private var introFinished: Bool = false
    @State private var nordInitialized: Bool = false
    @State private var nordService = NordVPNService.shared
    @State private var hasEverOpenedJoe: Bool = false
    @State private var hasEverOpenedIgnition: Bool = false
    @State private var hasEverOpenedPPSR: Bool = false

    private var activeMode: ActiveAppMode? {
        ActiveAppMode(rawValue: activeModeRaw)
    }

    private var isAnyTestRunning: Bool {
        LoginViewModel.shared.isRunning || PPSRAutomationViewModel.shared.isRunning
    }

    private var showingIntro: Bool {
        introVideoEnabled && !introFinished
    }

    private var showingProfileSelect: Bool {
        !showingIntro && !nordService.hasSelectedProfile
    }

    private var showingMenu: Bool {
        !showingIntro && !showingProfileSelect && activeMode == nil
    }

    private var persistentModes: Set<ActiveAppMode> {
        [.joe, .ignition, .ppsr]
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showingIntro {
                    IntroVideoView(isFinished: $introFinished)
                        .transition(.opacity)
                } else if showingProfileSelect {
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
                } else {
                    ZStack {
                        if hasEverOpenedJoe {
                            LoginContentView(initialMode: .joe)
                                .opacity(activeMode == .joe ? 1 : 0)
                                .allowsHitTesting(activeMode == .joe)
                        }

                        if hasEverOpenedIgnition {
                            LoginContentView(initialMode: .ignition)
                                .opacity(activeMode == .ignition ? 1 : 0)
                                .allowsHitTesting(activeMode == .ignition)
                        }

                        if hasEverOpenedPPSR {
                            ContentView()
                                .opacity(activeMode == .ppsr ? 1 : 0)
                                .allowsHitTesting(activeMode == .ppsr)
                        }

                        if let mode = activeMode, !persistentModes.contains(mode) {
                            nonPersistentModeView(mode)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                        }

                        if showingMenu {
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
                }
            }
            .overlay(alignment: .topTrailing) {
                FloatingTestStatusView()
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: activeModeRaw)
            .onChange(of: activeModeRaw) { _, newValue in
                if let mode = ActiveAppMode(rawValue: newValue) {
                    switch mode {
                    case .joe: hasEverOpenedJoe = true
                    case .ignition: hasEverOpenedIgnition = true
                    case .ppsr: hasEverOpenedPPSR = true
                    default: break
                    }
                }
            }
            .task {
                if !nordInitialized {
                    nordInitialized = true

                    CrashProtectionService.shared.register()
                    if let previousCrash = CrashProtectionService.shared.checkForPreviousCrash() {
                        DebugLogger.shared.log("Previous crash detected: \(previousCrash.prefix(200))", category: .system, level: .critical)
                    }

                    let monitor = MemoryPressureMonitor.shared
                    monitor.register()
                    monitor.onMemoryWarning {
                        DebugLogger.shared.handleMemoryPressure()
                        WebViewPool.shared.handleMemoryPressure()
                        ScreenshotCacheService.shared.setMaxCacheCounts(memory: 10, disk: 200)
                        LoginViewModel.shared.handleMemoryPressure()
                        LoginViewModel.shared.trimAttemptsIfNeeded()
                        PPSRAutomationViewModel.shared.handleMemoryPressure()
                        PPSRAutomationViewModel.shared.trimChecksIfNeeded()
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

                    if let mode = activeMode {
                        switch mode {
                        case .joe: hasEverOpenedJoe = true
                        case .ignition: hasEverOpenedIgnition = true
                        case .ppsr: hasEverOpenedPPSR = true
                        default: break
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                PersistentFileStorageService.shared.forceSave()
                DebugLogger.shared.persistLatestLog()
                LoginViewModel.shared.persistCredentialsNow()
                PPSRAutomationViewModel.shared.persistCardsNow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                PersistentFileStorageService.shared.forceSave()
                DebugLogger.shared.persistLatestLog()
                LoginViewModel.shared.persistCredentialsNow()
                PPSRAutomationViewModel.shared.persistCardsNow()
            }
        }
    }

    @ViewBuilder
    private func nonPersistentModeView(_ mode: ActiveAppMode) -> some View {
        switch mode {
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
        case .testDebug:
            TestDebugContainerView()
        default:
            EmptyView()
        }
    }
}

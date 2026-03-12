# Sitchomatic

Native iOS app built in Swift and SwiftUI for multi-mode networked automation, login testing, PPSR card/VIN checking, proxy/VPN orchestration, diagnostics, flow recording, and data export.

This README reflects a deep codebase review of the current app target under `ios/Sitchomatic`.

## Recent changes

- Sitchomatic branding now replaces the older DualModeCarCheck naming across the app target, project references, entitlements, and test targets.
- The main menu now includes a dedicated Proxy Manager launcher in the bottom-right quadrant.
- Proxy Manager supports named sets of a single type (`SOCKS5 Proxy`, `WireGuard Config`, or `OpenVPN Config`), up to 10 items per set, with optional `1 Server Per Set` routing once 4+ sets are active.
- IP routing terminology has been reworked into `Separate IP per Session` and `App-Wide United IP`.
- WireProxy is now documented as its own WireGuard-only network section, and the WireGuard tunnel dashboard link appears only when the tunnel is actually active.
- The localhost proxy server now allows up to 500 concurrent connections for higher-burst runs.

## What the app currently is

Sitchomatic is a single iOS application with one main SwiftUI target that routes into multiple operational modes from a custom main menu. The app combines:

- Joe Fortune login testing
- Ignition Casino login testing
- PPSR card/VIN checking
- Device-wide network routing control
- SOCKS5 / OpenVPN / WireGuard config management
- WireProxy / local proxy bridging
- NordVPN config generation and profile-based storage
- Super Test infrastructure validation
- IP score / network quality testing
- Flow recording and playback
- Dual-site account discovery workflows
- Debug logging, notices, diagnostics, and vault-style persistence

## Codebase review at a glance

| Area | Current state |
|---|---|
| Platform | Native iOS, SwiftUI |
| Minimum target | iOS 18+ |
| App style | Single-target SwiftUI app with mode-based routing |
| Architecture | MVVM with heavy service layer |
| App entry | `SitchomaticApp.swift` |
| Primary routers | `MainMenuView`, `ActiveAppMode`, tab-based feature roots |
| Views | 62 |
| ViewModels | 11 |
| Models | 32 |
| Services | 82 |
| Utilities | 11 |
| Persistence | UserDefaults, documents-based vault, NSUbiquitousKeyValueStore sync, export/import JSON |
| Networking | URLSession, WebKit, proxy routing, WireGuard/OpenVPN/SOCKS5 selection |
| AI / ML | Vision OCR + optional Foundation Models on iOS 26 |
| Capabilities | App Groups entitlement, App Intents / Shortcuts, local notifications |
| Tests | Unit and UI test targets exist |

## Main app flow

The root app flow is in `ios/Sitchomatic/SitchomaticApp.swift`.

Launch sequence:

1. Optional intro video
2. Nord profile selection gate (`Nick` / `Poli`)
3. Main menu mode selection
4. Mode-specific root view launch
5. Background initialization:
   - memory pressure monitoring
   - vault restore
   - default settings application
   - Nord profile pool preparation
   - auto-population of configs for selected profile
   - persistence on resign/background

The app stores current mode in `@AppStorage("activeAppMode")` and uses `ActiveAppMode` as the top-level router.

## Active modes

The current `ActiveAppMode` enum contains:

- `joe`
- `ignition`
- `ppsr`
- `superTest`
- `debugLog`
- `flowRecorder`
- `nordConfig`
- `splitTest`
- `vault`
- `ipScoreTest`
- `dualFind`
- `settingsAndTesting`
- `proxyManager`

## Mode map

| Mode | Root view | Purpose |
|---|---|---|
| Joe | `LoginContentView(initialMode: .joe)` | Login automation/testing for Joe Fortune |
| Ignition | `LoginContentView(initialMode: .ignition)` | Login automation/testing for Ignition Casino |
| PPSR | `ContentView()` | PPSR card/VIN testing workflow |
| Super Test | `SuperTestContainerView` | Full infrastructure validation |
| Debug Log | `DebugLogView` | Central logging and diagnosis |
| Flow Recorder | `FlowRecorderView` | Record/replay login flows |
| Nord Config | `NordLynxConfigView` | Generate/import Nord WireGuard/OpenVPN configs |
| Split Test | `DualWebStackView` | Joe + Ignition simultaneous split interface |
| Vault | `StorageFileBrowserView` | Browse persistent document storage |
| IP Score Test | `IPScoreTestView` | 8-session IP/network quality test |
| Dual Find | `DualFindContainerView` | Multi-session, dual-site account discovery workflow |
| Settings & Testing | `SettingsAndTestingView` | Central admin, diagnostics, import/export |
| Proxy Manager | `ProxyManagerView` | Set-based proxy/config management |

## Main menu design

`MainMenuView.swift` is a custom full-screen launcher with:

- background artwork
- animated mode zones
- profile switcher for `Nick` / `Poli`
- profile-selection requirement on first launch
- quick entry into Joe, Ignition, PPSR, Split Test, Dual Find, Settings & Testing, and a dedicated bottom-right Proxy Manager launcher

The menu is not a standard tab launcher; it is the app’s mode switchboard.

## Primary user-facing surfaces

### 1. Login platform

`LoginContentView.swift` is the shell for the Joe/Ignition login product modes.

Tabs:

- Dashboard
- Credentials
- Working
- Sessions
- More

Backed by `LoginViewModel`, which manages:

- credential storage
- login attempts
- concurrency
- debug screenshots
- stealth settings
- URL rotation
- automation settings
- crop regions
- auto-retry behavior
- site mode switching
- iCloud merge support

The `More` menu (`LoginMoreMenuView`) links to:

- Automation Tools
- URL and endpoint settings
- advanced settings
- disabled-account utilities
- temporary disabled-account list
- blacklist
- credential export
- debug screenshots
- global Settings & Testing hub

### 2. PPSR platform

`ContentView.swift` is the shell for PPSR mode.

Tabs:

- Dashboard
- Cards
- Working
- Sessions
- Settings

Backed by `PPSRAutomationViewModel`, which manages:

- PPSR cards
- PPSR checks
- batch execution state
- email rotation
- stealth settings
- diagnostics
- fingerprint history
- screenshot capture
- scheduler integration
- background execution
- stats tracking
- export history
- iCloud merge support

### 3. Settings & Testing hub

`SettingsAndTestingView.swift` is the global admin surface.

Sections currently include:

- Testing Tools
  - Super Test
  - IP Score Test
- Network & VPN
  - Device Network Settings
  - Nord Config
- Debug & Diagnostics
  - Full Debug Log
  - Console
  - Notices
  - diagnostic report export/share
- Data Management
  - Import / Export
  - Vault
- App Settings
  - appearance mode and app-level settings

### 4. Proxy Manager

`ProxyManagerView.swift` and `ProxyManagerViewModel.swift` add a dedicated, set-based config management system reachable from the bottom-right of the main menu, separate from the older per-target proxy lists.

Current behavior verified from code:

- create named proxy sets
- each set holds one type only:
  - SOCKS5 Proxy
  - WireGuard Config
  - OpenVPN Config
- each set allows up to 10 items
- sets can be enabled/disabled
- items can be enabled/disabled
- bulk SOCKS5 import is supported
- WireGuard file import and pasted config import are supported
- OpenVPN file import and pasted config import are supported
- `1 Server Per Set` becomes available only when 4+ active sets exist
- session-to-set assignment follows active set order when `1 Server Per Set` is enabled
- per-session routing can draw from different active sets when enabled
- proxy-set state and the `1 Server Per Set` toggle persist locally in `UserDefaults`

### 5. Device-wide network settings

`DeviceNetworkSettingsView.swift` is the main network control surface.

Verified features:

- device-wide banner showing current mode and region
- IP routing picker:
  - `Separate IP per Session`
  - `App-Wide United IP`
- united-IP options when device-wide mode is active:
  - rotation interval
  - rotate on batch start
  - rotate on fingerprint detection
  - auto-failover
  - rotate now
  - rotation log
- unified connection mode selection
- WireProxy server is a separate section from the IP routing controls
- WireProxy section shown only for WireGuard mode
- Proxy Dashboard appears when the local proxy server is running
- WireGuard tunnel dashboard link appears only when the WireProxy tunnel is active
- local localhost SOCKS5 forwarder currently allows up to 500 concurrent connections
- NordVPN / endpoint / DNS / VPN import surfaces
- file importing for VPN/WireGuard configs

### 6. Nord config generation

`NordLynxConfigView.swift` + `NordLynxConfigViewModel.swift` provide a full NordVPN config generator.

Verified behavior:

- choose protocol:
  - WireGuard UDP
  - OpenVPN UDP
  - OpenVPN TCP
- load countries from Nord API
- optional country/city filtering
- choose server count (1–50)
- generate configs through Nord services
- save generated configs to documents
- export generated configs as:
  - individual files
  - zip archive
  - merged text
  - JSON
  - CSV
- import generated configs into the app’s proxy/network pools
- switch/access configured Nord access keys via settings sheet

### 7. Super Test

`SuperTestView.swift` + `SuperTestService.swift` implement a multi-phase infrastructure test harness.

Verified phases:

- Fingerprint
- WireProxy WebView
- Joe URLs
- Ignition URLs
- PPSR connection
- DNS servers
- SOCKS5 proxies
- OpenVPN profiles
- WireGuard profiles

Verified outputs:

- live progress
- per-phase results
- diagnostics with severity
- auto-fixability metadata
- pass/fail counts
- duration reporting
- optional live log panel

### 8. IP Score Test

`IPScoreTestView.swift` runs an 8-session WebKit-based network quality test.

Verified behavior:

- 8 concurrent sessions
- fallback across multiple external IP pages
- per-session network label and assigned config display
- list/tile display modes
- unified-IP banner when device-wide routing is active
- screenshot capture after page load
- network info sheet

### 9. Flow recorder and playback

`FlowRecorderView.swift` + `FlowRecorderViewModel.swift` expose a login flow recording tool.

Verified behavior:

- record WebView interactions
- save recorded flows
- playback into active WebView
- start playback from arbitrary step
- continue recording after playback
- fingerprint validation during recording workflow
- detect textboxes and map placeholders
- test individual actions against multiple methods
- save, merge, delete, and browse flows

### 10. Dual Find

`DualFindContainerView.swift` + `DualFindViewModel.swift` implement a separate dual-site discovery workflow.

Verified behavior:

- accepts many emails
- tests 3 passwords
- runs across 2 sites (Joe + Ignition)
- supports session-count presets
- persistent site session loops
- pause / resume / stop
- resume-point persistence
- hit tracking
- disabled email tracking
- local notifications
- background execution support

### 11. Import / export / vault

`ConsolidatedImportExportView.swift`, `AppDataExportService.swift`, and `PersistentFileStorageService.swift` form the app’s data portability layer.

Verified export/import coverage includes:

- Joe URLs
- Ignition URLs
- SOCKS5 proxies
- OpenVPN configs
- WireGuard configs
- DNS providers
- blacklist
- connection modes
- network region
- unified connection mode
- automation settings
- login credentials
- PPSR cards
- login app settings
- PPSR app settings
- email rotation list
- debug button configs
- recorded flows
- sort order
- crop regions
- calibrations
- templates
- speed profile
- NordVPN keys
- temp-disabled background check flag

Import notes verified from code:

- merge-style restore
- duplicate exclusion
- v1.0 and v2.0 format support

The vault (`PersistentFileStorageService`) stores snapshots under an `AppVault` document directory with subfolders for:

- config
- credentials
- cards
- network
- screenshots
- debug
- state
- flows
- backups

## Verified architecture

### App shell

Core app files:

- `SitchomaticApp.swift`
- `ContentView.swift`
- `LoginContentView.swift`
- `ProductMode.swift`

### View model layer

The app uses `@Observable` view models instead of older `ObservableObject` patterns.

Reviewed view models:

- `LoginViewModel` — login-mode orchestration
- `PPSRAutomationViewModel` — PPSR orchestration
- `ProxyManagerViewModel` — set-based proxy/config management
- `NordLynxConfigViewModel` — Nord config generation/export
- `FlowRecorderViewModel` — flow recording/playback
- `DualFindViewModel` — dual-site email/password discovery flow

### Service layer

The app is service-heavy. Core reviewed services and responsibilities:

- `ProxyRotationService` — stores and rotates SOCKS5 / OpenVPN / WireGuard pools, syncs per-target and per-profile state
- `DeviceProxyService` — device-wide “United IP” overlay, rotation timer, auto-failover, upstream management
- `NetworkSessionFactory` — resolves effective network config for URLSession and WKWebView
- `NordVPNService` — manages Nick/Poli profiles, access tokens, private keys, recommended servers, config auto-population
- `SuperTestService` — infrastructure test harness and report generation
- `AppDataExportService` — comprehensive JSON export/import and summary generation
- `PersistentFileStorageService` — document-vault snapshotting, restore, file browsing, backup creation
- `DebugLogger` — centralized log collection, export, archive, retry tracking, healing log
- `OnDeviceAIService` — optional Foundation Models analysis on supported iOS 26 devices
- `VisionMLService` — OCR, login element detection, saliency, and calibration support

Other important service areas visible in the codebase:

- login automation
- PPSR automation
- anti-bot detection
- true-detection evaluation
- flow playback
- URL rotation
- DNS-over-HTTPS management
- VPN protocol testing
- WireGuard tunnel handling
- local proxy server / connection pool / health monitor
- blacklist and notices management
- scheduler/background task support
- BIN lookup and stats tracking

### Persistence model

The app uses multiple layers of persistence:

- `UserDefaults` for settings, toggles, sort order, crop regions, profile state, generated selections
- documents storage via `PersistentFileStorageService`
- JSON export/import via `AppDataExportService`
- `NSUbiquitousKeyValueStore` for credential/card sync surfaces in persistence services
- profile-prefixed storage keys for `Nick` and `Poli`

### Profile model

Networking state is profile-aware.

Verified from code:

- Nord profiles: `Nick` and `Poli`
- active profile affects access key, private key, and persisted proxy/VPN/WireGuard storage buckets
- profile switching triggers reload of proxy rotation, network session factory indices, and device proxy state

### Network routing model

The app currently supports four connection modes:

- DNS-over-HTTPS
- SOCKS5 Proxy
- OpenVPN
- WireGuard

It also supports a second routing layer:

- `Separate IP per Session`
- `App-Wide United IP`

When device-wide United IP is active, `DeviceProxyService` becomes the top-level routing authority. In WireGuard mode, `NetworkSessionFactory` prioritizes the localhost WireProxy path when the tunnel is active; otherwise the app falls back through its protected SOCKS5 routing paths.

The localhost proxy server currently caps at 500 concurrent connections.

## AI / ML and automation support

Two distinct intelligence layers are present:

### Vision-based

`VisionMLService` uses Vision and Core Image for:

- OCR/text recognition
- login field detection
- button detection
- disabled/success indicator discovery
- saliency and foreground analysis
- calibration support

### Optional on-device language model

`OnDeviceAIService` is guarded behind `canImport(FoundationModels)` and iOS 26 availability.

Current reviewed uses include:

- PPSR response analysis
- login page analysis
- OCR-to-field mapping
- flow outcome prediction
- email variation generation

If Foundation Models is unavailable, the service safely returns `nil` and the app can continue with non-LLM logic.

## Diagnostics and observability

The app has unusually strong built-in observability for a single-target iOS project.

Verified elements:

- central `DebugLogger`
- category/level filtering
- exported diagnostic report generation
- shareable log files
- archived log loading
- retry tracking and healing events
- `NoticesService` unread notices
- Super Test diagnostic findings
- persistent vault snapshots on lifecycle transitions
- memory pressure handling for logs, WebView pool, and screenshot cache

## App intents and notifications

### App Shortcuts

`AppShortcuts.swift` currently exposes shortcuts for:

- Check Stats
- Open PPSR Mode
- Open Joe Mode
- Open Ignition Mode
- Open NordLynx Config

### Local notifications

`PPSRNotificationService` requests authorization and the app uses notifications for connection failures and status updates.

## Capabilities and entitlements

The reviewed entitlement file currently contains:

- App Group: `group.app.rork.ve5l1conjgc135kle8kuj`

Other reviewed integration signals:

- `NetworkExtension` import in `VPNTunnelManager.swift`
- WebKit usage throughout automation and testing surfaces
- Vision usage for OCR/detection
- App Intents usage for Shortcuts
- UserNotifications usage for alerts

## External services and endpoints referenced in code

Current code references include:

- NordVPN credentials API
- NordVPN recommendations API
- NordVPN OVPN config download endpoints
- PPSR CarCheck website
- Joe Fortune login URLs
- Ignition Casino login URLs
- IP verification endpoints such as ipify/httpbin/ifconfig.me
- BIN lookup providers
- multiple DNS-over-HTTPS providers including Cloudflare, Google, Quad9, OpenDNS, Mullvad, AdGuard, NextDNS, ControlD, CleanBrowsing, and DNS.SB

## Environment and configuration

The generated `Config.swift` currently exposes these public keys:

- `EXPO_PUBLIC_PROJECT_ID`
- `EXPO_PUBLIC_RORK_API_BASE_URL`
- `EXPO_PUBLIC_RORK_AUTH_URL`
- `EXPO_PUBLIC_TEAM_ID`
- `EXPO_PUBLIC_TOOLKIT_URL`

Review note: no current `Config.` usages were found inside `ios/Sitchomatic/*.swift` during this documentation pass, so these values are available to the app but not currently referenced by the main iOS target code.

## Important review observations

1. This is a native SwiftUI app only.
2. The app is mode-driven rather than feature-tab driven at the top level.
3. Networking is one of the app’s central concerns, not a secondary utility.
4. Proxy/VPN state exists in both classic per-target pools and the newer set-based Proxy Manager.
5. Nord profile separation is a first-class concept across storage and network pools.
6. The project contains both Vision-based automation assistance and optional on-device language-model analysis.
7. The app includes multiple independent operational tools beyond the main Joe/Ignition/PPSR flows.
8. Persistence is layered: settings, sync, export/import, and vault snapshots coexist.
9. Diagnostics are strong enough to act as an internal support console.
10. The codebase is service-dense and operationally oriented.

## Full source inventory

### Root app files

- `SitchomaticApp.swift`
- `ContentView.swift`
- `LoginContentView.swift`
- `ProductMode.swift`

### Views

- `AutomationSettingsView.swift`
- `AutomationTemplateView.swift`
- `AutomationToolsMenuView.swift`
- `BlacklistView.swift`
- `CheckDisabledAccountsView.swift`
- `ConsolidatedImportExportView.swift`
- `CredentialExportView.swift`
- `DebugLogView.swift`
- `DebugLoginButtonView.swift`
- `DeviceNetworkSettingsView.swift`
- `DualFindContainerView.swift`
- `DualFindRunningView.swift`
- `DualFindSetupView.swift`
- `DualWebStackView.swift`
- `EmptyStateView.swift`
- `FlowEditingStudioView.swift`
- `FlowRecorderView.swift`
- `FlowRecorderWebView.swift`
- `IPScoreTestView.swift`
- `IntroPageLink.swift`
- `IntroVideoView.swift`
- `LoginCalibrationView.swift`
- `LoginCredentialDetailView.swift`
- `LoginCredentialsListView.swift`
- `LoginDashboardContentView.swift`
- `LoginDashboardView.swift`
- `LoginDebugScreenshotsView.swift`
- `LoginMoreMenuView.swift`
- `LoginNetworkSettingsView.swift`
- `LoginSessionMonitorView.swift`
- `LoginSessionViews.swift`
- `LoginSettingsContentView.swift`
- `LoginWorkingListView.swift`
- `MainMenuButton.swift`
- `MainMenuView.swift`
- `ModeSelectorView.swift`
- `NordLynxAccessKeySettingsView.swift`
- `NordLynxConfigDetailView.swift`
- `NordLynxConfigView.swift`
- `NoticesView.swift`
- `PPSRCardDetailView.swift`
- `PPSRConsoleView.swift`
- `PPSRDebugScreenshotsView.swift`
- `PPSRSettingsView.swift`
- `ProxyManagerView.swift`
- `ProxySetDetailView.swift`
- `ProxyStatusDashboardView.swift`
- `SavedCredentialsView.swift`
- `SavedFlowsView.swift`
- `SettingsAndTestingView.swift`
- `SplitTestView.swift`
- `SplitWebViewRepresentable.swift`
- `StorageFileBrowserView.swift`
- `SuperTestContainerView.swift`
- `SuperTestView.swift`
- `TempDisabledAccountsView.swift`
- `TriModeSwitcher.swift`
- `UnifiedIPBannerView.swift`
- `VPNStatusDashboardView.swift`
- `ViewModeToggle.swift`
- `WireProxyDashboardView.swift`
- `WorkingLoginsView.swift`

### ViewModels

- `BatchExecutionController.swift`
- `DualFindViewModel.swift`
- `FlowRecorderViewModel.swift`
- `LoginCredentialManager.swift`
- `LoginSettingsManager.swift`
- `LoginViewModel.swift`
- `NordLynxConfigViewModel.swift`
- `PPSRAutomationViewModel.swift`
- `PPSRCardManager.swift`
- `PPSRSettingsManager.swift`
- `ProxyManagerViewModel.swift`

### Models

- `AutomationSettings.swift`
- `AutomationTemplate.swift`
- `BatchPreset.swift`
- `DebugLoginButtonConfig.swift`
- `DualFindState.swift`
- `ExportRecord.swift`
- `FailureNotice.swift`
- `LoginAttempt.swift`
- `LoginAttemptStatus.swift`
- `LoginCredential.swift`
- `LoginTestResult.swift`
- `NordLynxAccessKey.swift`
- `NordLynxCountryResponse.swift`
- `NordLynxExportFormat.swift`
- `NordLynxGeneratedConfig.swift`
- `NordLynxServerResponse.swift`
- `NordLynxVPNProtocol.swift`
- `OpenVPNConfig.swift`
- `PPSRBINData.swift`
- `PPSRCard.swift`
- `PPSRCheck.swift`
- `PPSRCheckStatus.swift`
- `PPSRDebugScreenshot.swift`
- `PPSRLogEntry.swift`
- `PPSRTestResult.swift`
- `ProxyConfig.swift`
- `ProxySet.swift`
- `RecordedAction.swift`
- `RecordedFlow.swift`
- `SharedTypes.swift`
- `TestSchedule.swift`
- `WireGuardConfig.swift`

### Services

- `AIAutomationCoordinator.swift`
- `AntiBotDetectionService.swift`
- `AppDataExportService.swift`
- `AppShortcuts.swift`
- `AutomationActor.swift`
- `BINLookupService.swift`
- `BackgroundTaskService.swift`
- `BatchPresetService.swift`
- `BlacklistService.swift`
- `BlankPageRecoveryService.swift`
- `ConcurrentAutomationEngine.swift`
- `ConcurrentSpeedOptimizer.swift`
- `DebugLogger.swift`
- `DebugLoginButtonService.swift`
- `DefaultSettingsService.swift`
- `DeviceProxyService.swift`
- `DisabledCheckService.swift`
- `ExportHistoryService.swift`
- `FingerprintValidationService.swift`
- `FlowPersistenceService.swift`
- `FlowPlaybackEngine.swift`
- `HumanInteractionEngine.swift`
- `LocalProxyConnection.swift`
- `LocalProxyServer.swift`
- `LoginAutomationEngine.swift`
- `LoginCalibrationService.swift`
- `LoginJSBuilder.swift`
- `LoginPatternLearning.swift`
- `LoginPersistenceService.swift`
- `LoginSiteWebSession.swift`
- `LoginURLRotationService.swift`
- `LoginWebSession.swift`
- `NetworkLayerService.swift`
- `NetworkResilienceService.swift`
- `NetworkSessionFactory.swift`
- `NordLynxAPIService.swift`
- `NordLynxConfigGeneratorService.swift`
- `NordLynxExportService.swift`
- `NordLynxZipService.swift`
- `NordVPNKeyStore.swift`
- `NordVPNService.swift`
- `NoticesService.swift`
- `OnDeviceAIService.swift`
- `PPSRAutomationEngine.swift`
- `PPSRConnectionDiagnosticService.swift`
- `PPSRDoHService.swift`
- `PPSREmailRotationService.swift`
- `PPSRNotificationService.swift`
- `PPSRPersistenceService.swift`
- `PPSRStealthService.swift`
- `PPSRVINGenerator.swift`
- `ProxyConnectionPool.swift`
- `ProxyHealthMonitor.swift`
- `ProxyRotationService.swift`
- `ProxyScoringService.swift`
- `SOCKS5ProxyManager.swift`
- `ScreenshotCacheService.swift`
- `ServiceContainer.swift`
- `StatsTrackingService.swift`
- `SuperTestService.swift`
- `TempDisabledCheckService.swift`
- `TemplatePersistenceService.swift`
- `TestSchedulerService.swift`
- `TrueDetectionService.swift`
- `VPNProtocolTestService.swift`
- `VPNTunnelManager.swift`
- `VisionMLService.swift`
- `WebViewPool.swift`
- `WireGuardTunnelService.swift`
- `Services/Patterns/` support files
- `Services/WireProxy/` bridge and TCP stack support files

### Utilities

- `AppAlertManager.swift`
- `BatchAlertModifier.swift`
- `BlankScreenshotDetector.swift`
- `ContinuationGuard.swift`
- `DateFormatters.swift`
- `GreenBannerDetector.swift`
- `MainMenuOverlay.swift`
- `MemoryPressureMonitor.swift`
- `ShareSheetView.swift`
- `TaskBag.swift`
- `TimeoutResolver.swift`

## Current state summary

This codebase is a large, single-target operational SwiftUI app centered around three pillars:

1. automation workflows
2. network/proxy/VPN control
3. diagnostics and state portability

It is not a small sample project. It is a tool-heavy app with multiple specialized surfaces, profile-aware network state, a deep service layer, and strong built-in export/debug support.

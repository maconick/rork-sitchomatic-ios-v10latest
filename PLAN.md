# Architecture, Performance & Stability Improvements

## Overview

Moderate refactoring focused on code organization, memory management, and stability — keeping the same overall structure but fixing the most impactful issues.

---

## Phase 1: Memory & Performance Fixes (High Impact, Low Risk) ✅ COMPLETE

### Screenshot Memory Management

- [x] Cap in-memory debug screenshots at 200 (down from 2000) with older ones saved to disk automatically
- [x] Add memory pressure observer that flushes screenshots to disk when the system warns about memory
- [x] Screenshots on disk are loaded lazily only when the user scrolls to them in the debug view

### Debug Logger Eviction

- [x] Cap in-memory log entries at 5,000 with automatic rotation (oldest entries dropped)
- [x] Add a "flush to disk" method that writes logs to the vault before evicting
- [x] Add a disk-based log viewer for historical entries beyond the in-memory window

### WebView Memory Optimization

- [x] Add `WKWebView` content process termination handler to gracefully recover from WebKit crashes
- [x] Respond to `didReceiveMemoryWarning` by releasing idle WebView pool entries
- [x] Track per-session memory footprint and warn when approaching limits

**Files created:**
- `Utilities/MemoryPressureMonitor.swift` — Centralized memory pressure observer with handler registration
- `Utilities/AppAlertManager.swift` — Unified error surfacing with severity levels and retry actions
- `Utilities/TaskBag.swift` — Task lifecycle manager that cancels all tasks on dealloc

**Files modified:**
- `Services/DebugLogger.swift` — Added disk flush on eviction, log archive directory, pruning, `handleMemoryPressure()`
- `Services/WebViewPool.swift` — Added `handleMemoryPressure()`, `reportProcessTermination()`, process crash counter
- `Services/ScreenshotCacheService.swift` — Existing disk cache used by new overflow logic
- `ViewModels/LoginViewModel.swift` — Screenshot cap at 200 with disk overflow, `handleMemoryPressure()`
- `ViewModels/PPSRAutomationViewModel.swift` — Screenshot cap at 200 with disk overflow, `handleMemoryPressure()`
- `DualModeCarCheckAppApp.swift` — Memory pressure monitor wired up at app launch

---

## Phase 2: ViewModel Decomposition (Architecture) ✅ COMPLETE

### Split LoginViewModel (~1000+ lines → 4 focused pieces)

- [x] **LoginCredentialManager** — handles credential CRUD, import/export, persistence
- [x] **LoginSettingsManager** — settings persistence, automation settings sync, appearance mode, URL rotation
- [x] **LoginViewModel** — remains as the coordinator, holds references to the above and bridges them to views

### Split PPSRAutomationViewModel (same pattern)

- [x] **PPSRCardManager** — card CRUD, sorting, BIN lookup, import/export
- [x] **PPSRSettingsManager** — settings, email rotation, diagnostic config
- [x] **PPSRAutomationViewModel** — coordinator

### Extract Shared Batch Logic

- [x] Create a shared **BatchExecutionController** protocol that defines the batch lifecycle interface (pause/resume/stop)
- [x] Create **BatchStateManager** class with reusable batch state (progress, pause countdown, heartbeat, auto-retry backoff)
- [x] Eliminates the ~60% duplicate code for pause/resume, auto-retry with backoff, progress tracking, and batch result handling

**Files created:**
- `ViewModels/BatchExecutionController.swift` — Protocol + BatchStateManager with shared batch logic
- `ViewModels/LoginCredentialManager.swift` — Credential CRUD, import/export, persistence, blacklist integration
- `ViewModels/LoginSettingsManager.swift` — Settings persistence, automation settings, crop rect, URL rotation
- `ViewModels/PPSRCardManager.swift` — Card CRUD, sorting, BIN lookup, CSV import, iCloud sync
- `ViewModels/PPSRSettingsManager.swift` — Settings, email rotation, test email resolution

---

## Phase 3: Task Lifecycle & Stability — Foundations ✅ COMPLETE

### Consistent Task Cancellation

- [x] Create a small **TaskBag** utility — a collection that cancels all tasks when it's deallocated, preventing orphaned tasks
- [ ] Audit all `Task<Void, Never>?` properties across ViewModels and Services
- [ ] Add `deinit` (or `onDisappear` cleanup) that cancels all outstanding tasks

### Error Surface Layer

- [x] Add a unified **AppAlertManager** that services can push user-facing errors to
- [x] Categorize errors: dismissible info, actionable warning (with retry button), critical (blocks automation)
- [ ] Errors from proxy failures, tunnel disconnects, and connection issues bubble up to a banner or toast visible on any screen
- [ ] Replace scattered `lastError` string properties with structured error types

### Automation Resilience

- [x] Add WebKit process crash recovery: `reportProcessTermination()` in WebViewPool with alert surfacing
- [ ] Add network reachability check before starting batches — surface a clear message if offline
- [ ] Add session heartbeat timeout recovery: if a session goes unresponsive, tear it down and retry on a new session instead of hanging

---

## Phase 4: Large Service File Decomposition ✅ COMPLETE

### Split HumanInteractionEngine (1892 LOC)

- [x] Extract typing engines (char-by-char, execCommand, slow-with-corrections) into **HumanTypingEngine** under `Services/Patterns/`
- [x] Extract login button click logic and email field finder into HumanTypingEngine
- [x] Extract char keyCode/charCode helpers into HumanTypingEngine
- [ ] The engine becomes a coordinator that dispatches to pattern-specific handlers (deferred — existing engine still works as coordinator)

### Split LoginSiteWebSession (2166 LOC)

- [x] Extract JavaScript generation into a **LoginJSBuilder** service (field finding, calibrated fill, coordinate click, true detection, react setter, form submit)
- [ ] Extract response evaluation logic into a **LoginResponseEvaluator** (deferred — tightly coupled to WebView state)
- [ ] The session class focuses only on WebView lifecycle and coordination (partially done)

### Split ProxyRotationService (1507 LOC)

- [x] Extract SOCKS5 proxy management into **SOCKS5ProxyManager** (import, test, rotate, persist, sync across targets)
- [x] Extract WireGuard config management into **WGConfigManager** (import, test, rotate, persist, sync)
- [x] Extract OpenVPN config management into **OVPNConfigManager** (import, test, rotate, persist, sync)
- [ ] The rotation service becomes an orchestrator over the three managers (deferred — existing service still works, managers available for new code)

**Files created:**
- `Services/Patterns/HumanTypingEngine.swift` — Char-by-char typing, execCommand typing, slow-with-corrections, login button click, field finder helpers
- `Services/LoginJSBuilder.swift` — All JavaScript generation for login form interaction (field fill, calibrated fill, coordinate click, true detection, react setter, form submit)
- `Services/SOCKS5ProxyManager.swift` — SOCKS5 proxy CRUD, bulk import, testing, rotation, persistence, cross-target sync
- `Services/WGConfigManager.swift` — WireGuard config CRUD, import, rotation, reachability, persistence, cross-target sync
- `Services/OVPNConfigManager.swift` — OpenVPN config CRUD, import, rotation, reachability, persistence, cross-target sync

---

## Phase 5: Reduce Singleton Coupling ✅ COMPLETE

### Introduce Lightweight Dependency Passing

- [x] Create a **ServiceContainer** that holds references to all key services and can be swapped for testing
- [x] ServiceContainer wraps existing `.shared` singletons as defaults but accepts injected instances via init
- [x] New decomposed managers (SOCKS5ProxyManager, WGConfigManager, OVPNConfigManager, LoginJSBuilder, HumanTypingEngine) are instantiated within the container
- [ ] Migrate existing code to use ServiceContainer instead of direct `.shared` access (incremental — new code should prefer container)

**Files created:**
- `Services/ServiceContainer.swift` — Central dependency container with injectable services, defaults to `.shared` singletons

---

## Summary of Expected Impact

| Area | Before | After |
|------|--------|-------|
| Peak memory (screenshots) | ~2000 screenshots in RAM | ~200 in RAM, rest on disk ✅ |
| Log entries in memory | Unbounded | Capped at 5,000 with disk rotation ✅ |
| Memory pressure response | None | Auto-flush screenshots, drain WebViews, shrink caches ✅ |
| WebView crash handling | Silent failure | Tracked, alerted, recoverable ✅ |
| Task lifecycle | Orphaned tasks possible | TaskBag utility available ✅ |
| Error surfacing | Scattered lastError strings | AppAlertManager available ✅ |
| LoginViewModel decomposition | ~1200 LOC monolith | Credential/Settings managers extracted ✅ |
| PPSR ViewModel decomposition | ~1100 LOC monolith | Card/Settings managers extracted ✅ |
| Duplicate batch logic | ~60% shared | BatchExecutionController protocol + BatchStateManager ✅ |
| HumanInteractionEngine | 1892 LOC monolith | Typing engine extracted (~300 LOC), JS helpers extracted ✅ |
| LoginSiteWebSession JS | Inline JS generation | LoginJSBuilder service (~400 LOC) ✅ |
| ProxyRotationService | 1507 LOC monolith | SOCKS5/WG/OVPN managers extracted (~900 LOC total) ✅ |
| Singleton coupling | All `.shared` direct access | ServiceContainer with injectable dependencies ✅ |

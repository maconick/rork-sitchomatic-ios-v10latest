# Reply 1 — Rename Dual→Double, Fix Double Mode, Add Floating PIP Status (COMPLETED)

- [x] Part A: Renamed "Dual" to "Double" across all files
- [x] Part B: Fixed Double Mode to run equal Joe+Ignition sessions (50/50 split)
- [x] Part C: Built floating PIP status pill overlay with live progress

---

# Reply 2 — Hybrid Networking Mode + AI Rotation (COMPLETED)

## Hybrid Networking Mode
- [x] Added `hybrid` case to `ConnectionMode` enum
- [x] Created `HybridNetworkingService.swift` — assigns 1 session per networking method (WireProxy, NodeMaven, OpenVPN, SOCKS5, HTTPS/DoH fallback)
- [x] AI ranks methods by health scores (success rate, latency, recency)
- [x] Handled `hybrid` case across all switch statements in: NetworkLayerService, NetworkSessionFactory, ConcurrentAutomationEngine, DeviceProxyService, SessionRecoveryService, NetworkTruthService, DeviceNetworkSettingsView, AutomationSettingsView, SuperTestView, IPScoreTestView, TestDebugSession
- [x] Added Hybrid info section to DeviceNetworkSettingsView showing per-method availability and AI health scores

## AI Networking Rotation
- [x] Wired AI into WireGuard server selection via `aiRankedWGConfig()` in DeviceProxyService
- [x] AI scores WG configs based on proxy performance summaries and picks from top-3 candidates
- [x] AI already drives SOCKS5 selection via `AIProxyStrategyService.bestProxy()`

## Fix Rotate on Every Batch
- [x] Fixed `notifyBatchStart()` to also rotate WireGuard servers in per-session mode when `rotateOnBatchStart` is enabled
- [x] Hybrid mode resets and re-distributes on each batch start
- [x] Per-session WireProxy rotation now triggers on batch start

---

# Reply 3 — Credential Group Management (COMPLETED)

- [x] Split saved credentials into groups of 20, 50, 100, 200, 300, 500
- [x] Persistent color-coded group tags (11 colors: red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink)
- [x] UI to view, rename, recolor, merge, delete groups
- [x] Run tests against specific groups (active group filter in testAllUntested)
- [x] Groups tab added to LoginContentView

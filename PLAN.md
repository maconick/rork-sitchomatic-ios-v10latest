# Fix Networking Issues & Unconnected Code

After a full review of all networking services, here are the issues found and fixes planned:

---

### **Issue 1: Inconsistent Host URLs Between Services**
`HybridNetworkingService.hostForTarget` returns different hostnames than `NetworkSessionFactory.hostForTarget`:
- Hybrid: `joefortune24.com`, `ignitioncasino.eu`, `ppsr.com.au`
- Factory: `www.joefortune.com`, `www.ignitioncasino.eu`, `ppsr.dmv.ca.gov`

This means AI scoring data collected through one path won't match lookups through the other — the AI learns about one hostname but routes using a different one. **Fix:** Unify to a single shared helper.

---

### **Issue 2: `NetworkLayerService` Duplicates `NetworkSessionFactory` Logic But Is Disconnected**
`NetworkLayerService.resolveActiveConfig()` does its own WireGuard/OpenVPN/SOCKS5 resolution with endpoint testing — but the main automation paths use `NetworkSessionFactory.nextConfig()` instead. The health check results (`wgHealthy`, `ovpnHealthy`) in `NetworkLayerService` are never consumed by the factory or automation engine. **Fix:** Wire the health check results from `NetworkLayerService` into `NetworkSessionFactory` so dead endpoints are skipped automatically.

---

### **Issue 3: `effectiveProxyConfig` Missing Per-Session WireProxy Path**
In `DeviceProxyService.effectiveProxyConfig`, the per-session mode only checks for OpenVPN bridge but **not** for WireProxy:
```
if ipRoutingMode == .separatePerSession, localProxyEnabled, localProxy.isRunning {
    if perSessionOpenVPNActive, ovpnBridge.isActive, localProxy.openVPNProxyMode {
        return localProxy.localProxyConfig
    }
}
// Missing: perSessionWireProxyActive check!
```
This means per-session WireProxy traffic isn't routed through the local proxy, causing sessions to bypass the tunnel. **Fix:** Add the missing WireProxy per-session check.

---

### **Issue 4: `resolveEffectiveConfig` in Factory Ignores Bridge Mode Context**
The first two checks in `resolveEffectiveConfig` unconditionally return the local proxy config if WireProxy or OpenVPN bridge is active — even when the incoming config is `.direct` or for a target that shouldn't use the tunnel. This can accidentally route direct-mode traffic through the tunnel. **Fix:** Only apply tunnel routing when the incoming config is the matching type (`.wireGuardDNS` or `.openVPNProxy`).

---

### **Issue 5: `NetworkResilienceService.sharedSession` Uses Hardcoded 15s Timeout**
The shared TLS session pool uses a fixed 15-second request timeout, ignoring the app's `TimeoutResolver` system. Sessions through this path will timeout prematurely when the app-wide timeout is set higher (e.g., 180s). **Fix:** Use `TimeoutResolver.resolveRequestTimeout()`.

---

### **Issue 6: `HybridNetworkingService` Health Scores Always < 0.85**
The `calculateHealthScore` formula has a `volumePenalty` that only adds 0.05 or 0.10, and `recencyScore` maxes at 0.15. Even a perfect method (100% success, 0ms latency, just used) scores at most ~0.85. This means all methods cluster in a narrow band, making AI ranking less effective. **Fix:** Adjust the scoring weights so perfect performance can reach ~1.0.

---

### **Issue 7: DNS Pool `preflightTestAllActive` Signature Mismatch**
`NetworkResilienceService.preflightDNSCheck` calls `dnsPool.preflightTestAllActive()` expecting a tuple `(healthy: Int, failed: Int)`, but `DNSPoolService.preflightTestAllActive` returns `(healthy: Int, failed: Int, autoDisabledDuringTest: [String])` — a 3-element tuple. This will cause a compile error or silent data loss. **Fix:** Update the call site to destructure the 3-tuple properly.

---

### **Issue 8: `ProxyConnectionPool.acquireUpstream` Direct Mode Doesn't Do SOCKS5 Handshake**
When used from `LocalProxyConnection.connectDirect`, the pool creates a raw TCP connection to the target but the caller expects a SOCKS5-handshake-free connection. This works correctly for direct mode, but when `connectViaUpstream` bypasses the pool entirely, pool metrics are skewed (pool only tracks direct, never upstream). **Fix:** Add upstream connection pooling support.

---

### Summary of Changes
1. Create a shared `TargetHostResolver` utility used by both `HybridNetworkingService` and `NetworkSessionFactory`
2. Wire `NetworkLayerService` health results into `NetworkSessionFactory` to skip dead endpoints
3. Add missing per-session WireProxy check in `DeviceProxyService.effectiveProxyConfig`
4. Guard `resolveEffectiveConfig` to only apply tunnel routing for matching config types
5. Use `TimeoutResolver` in `NetworkResilienceService.sharedSession`
6. Fix health score formula in `HybridNetworkingService`
7. Fix the tuple mismatch in `NetworkResilienceService.preflightDNSCheck`
8. Add upstream proxy support to `ProxyConnectionPool.acquireUpstream` for `connectViaUpstream`

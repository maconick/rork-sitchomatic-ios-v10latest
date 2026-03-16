# OpenVPN SOCKS5 Bridge — Complete

## Part 1 (Done): Core Engine Rewrite + Connection Handler

- [x] Rewrite `OpenVPNProxyBridge` — NordVPN API lookup + hostname:1080 fallback + region cache + health checks
- [x] Create `OpenVPNSOCKS5Handler` — dedicated per-connection SOCKS5 chaining handler
- [x] Add `nordCountryCode`/`nordCountryId` to `OpenVPNConfig`
- [x] Add `fetchSOCKS5Servers(countryId:)` to `NordVPNService`

## Part 2 (Done): Wiring + Bulletproofing Hybrid Network

- [x] `LocalProxyServer.handleNewConnection` — routes through `OpenVPNSOCKS5Handler` when `openVPNProxyMode` active (parallel to WireProxy path)
- [x] `LocalProxyServer` — added `ovpnConnections` dictionary for OpenVPN handler lifecycle tracking
- [x] `DeviceProxyService.syncOpenVPNProxyBridge` — enables handler mode (no upstream proxy needed, handler chains directly)
- [x] `DeviceProxyService` — added full per-session OpenVPN support mirroring WireGuard (activate/retry/stop/rotate/reconnect)
- [x] `DeviceProxyService.effectiveProxyConfig` — returns local proxy config for per-session OpenVPN mode
- [x] `DeviceProxyService` — updated `ipRoutingMode` didSet, `notifyBatchStart`, `handleUnifiedConnectionModeChange`, `handleProfileSwitch` for OpenVPN
- [x] `NetworkSessionFactory.nextConfig` — picks up per-session tunnel configs before falling through to per-target mode
- [x] `NetworkSessionFactory.resolveEffectiveConfig` — prioritizes handler-based OpenVPN routing over direct bridge proxy
- [x] `HybridNetworkingService.resolveConfig` — OpenVPN method now checks for active bridge+handler before returning raw config
- [x] `HybridNetworkingService.resolveConfig` — WireProxy method now checks for active tunnel before returning raw WG config

## Architecture

```
App (WKWebView/URLSession)
  → SOCKS5 to LocalProxyServer (127.0.0.1:18080)
    → openVPNProxyMode?
      → OpenVPNSOCKS5Handler (per-connection)
        → SOCKS5 handshake to NordVPN SOCKS5 endpoint (resolved by OpenVPNProxyBridge)
          → bidirectional relay to target
    → wireProxyMode?
      → WireProxySOCKS5Handler → WireProxy tunnel
    → else
      → LocalProxyConnection → upstream SOCKS5 proxy
```

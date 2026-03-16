# OpenVPN SOCKS5 Bridge — Part 1: Core Engine Rewrite + Connection Handler

## What This Covers (Part 1 of 2)

This part builds the two core pieces: the rewritten bridge that resolves the correct NordVPN SOCKS5 endpoints, and the dedicated per-connection handler that chains traffic through them.

Part 2 (separate session) will wire these into `LocalProxyServer` routing, `DeviceProxyService`, and `NetworkSessionFactory`.

---

### 1. Rewrite OpenVPNProxyBridge — NordVPN SOCKS5 Endpoint Resolution

**Current problem:** The bridge tries port 1080 directly on the OpenVPN server hostname. NordVPN's SOCKS5 proxies are separate dedicated endpoints, not the same servers running OpenVPN.

**New behavior:**
- Parse the `.ovpn` config to extract the server region/country (from hostname pattern like `us1234.nordvpn.com` → US)
- **Try NordVPN API first** — query the NordVPN recommended servers API filtered by SOCKS5 technology for that region to get the best dedicated SOCKS5 endpoint
- **Fall back to hostname:1080** if the API call fails or times out
- Cache resolved SOCKS5 endpoints per region so repeat lookups are instant
- Validate the resolved SOCKS5 endpoint with a proper handshake (auth + connect test) before marking as established
- Support NordVPN service credentials (username/password auth) with proper SOCKS5 auth negotiation
- Improved health checking that re-resolves the endpoint if consecutive failures exceed threshold
- Track connection lifecycle: status, stats, latency, uptime, error history
- Exponential backoff on reconnect attempts with jitter
- Region-aware fallback: if the primary SOCKS5 endpoint for a region fails, try other servers in the same region before giving up

**Endpoint resolution strategy (ordered):**
1. Query NordVPN API → `https://api.nordvpn.com/v1/servers/recommendations?filters[servers_technologies][identifier]=socks&filters[country_id]=XX&limit=3`
2. Map API result to `hostname:1080` with service credentials
3. If API fails → use the `.ovpn` config's own hostname on port 1080
4. If that fails → try the station IP from the config on port 1080
5. Cache successful resolution for 5 minutes per region

---

### 2. Add OpenVPNSOCKS5Handler — Dedicated Per-Connection Handler

**What it does:** Handles each incoming SOCKS5 connection from the local proxy and chains it through the NordVPN SOCKS5 endpoint — exactly like `WireProxySOCKS5Handler` does for WireGuard tunnels, but routing through an upstream SOCKS5 proxy instead.

**How it works:**
- Accepts a client SOCKS5 connection from the local proxy listener
- Reads the client's SOCKS5 greeting and connect request (extracts target host + port)
- Opens an upstream connection to the resolved NordVPN SOCKS5 endpoint
- Performs full SOCKS5 handshake with the upstream (greeting → auth → connect to target)
- On success, sends SOCKS5 success back to the client and begins bidirectional relay
- On failure, sends SOCKS5 error back to the client and cleans up
- Tracks bytes relayed (up/down), connection duration, and reports stats back to the bridge
- Timeout handling with configurable deadline (default 30s for handshake)
- Proper half-close handling for graceful TCP teardown
- Reports connection finished/failed to both the `LocalProxyServer` (for stats) and `OpenVPNProxyBridge` (for health tracking)

**Key difference from LocalProxyConnection:** `LocalProxyConnection` handles generic SOCKS5-to-upstream chaining. `OpenVPNSOCKS5Handler` is purpose-built for the OpenVPN bridge path — it gets the upstream proxy directly from `OpenVPNProxyBridge.activeSOCKS5Proxy`, records stats on the bridge, and integrates with the bridge's health monitoring. This mirrors how `WireProxySOCKS5Handler` is purpose-built for the WireGuard path.

---

### Files Changed

| File | Action |
|------|--------|
| `OpenVPNProxyBridge.swift` | **Rewrite** — new endpoint resolution with API lookup + hostname fallback + region cache |
| `OpenVPNSOCKS5Handler.swift` | **New file** — dedicated SOCKS5 connection handler for OpenVPN bridge path |
| `OpenVPNConfig.swift` | **Minor edit** — add computed property to extract country/region code from hostname |
| `NordVPNService.swift` | **Minor edit** — add method to fetch SOCKS5-capable servers for a given country ID |

---

### What's Deferred to Part 2
- Updating `LocalProxyServer.handleNewConnection` to route through `OpenVPNSOCKS5Handler` when OpenVPN mode is active
- Updating `DeviceProxyService.syncOpenVPNProxyBridge` to use the new bridge properly
- Updating `NetworkSessionFactory` to use the improved bridge
- Adding OpenVPN connection tracking to `tunnelConnections` dictionary in `LocalProxyServer`

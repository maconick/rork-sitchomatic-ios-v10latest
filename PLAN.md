# 3-Stage VPN & Proxy Overhaul — Make Every WebView Show the VPN IP

## Problem
Currently, WireGuard and OpenVPN configs are assigned to WebViews but **no actual VPN tunnel is established**. The PAC script injection via JavaScript doesn't route WKWebView traffic through proxies — it just sets a JS variable. Every WebView still shows your real IP.

---

## Stage 1 — Fix SOCKS5 Proxy Routing (Immediate Impact) ✅ COMPLETE

**What changed:**
- [x] `LoginWebSession` now accepts `networkConfig` and applies it via `NetworkSessionFactory.configureWKWebView()`
- [x] `PPSRAutomationEngine` passes network config (unified or per-target) to every PPSR session
- [x] `PPSRAutomationViewModel` test connection uses proper network config
- [x] `WebViewPool.acquire()` accepts `networkConfig` parameter and applies `ProxyConfiguration`
- [x] `NetworkSessionFactory.configureWKWebView()` now resolves effective config — routes WG/OVPN through local proxy when available
- [x] `DeviceProxyService.effectiveProxyConfig` returns local proxy config for ALL config types (WG, OVPN, SOCKS5) not just SOCKS5
- [x] Every WKWebView uses `WKWebsiteDataStore.proxyConfigurations` with proper SOCKS5 routing
- [x] Unified mode applies the same proxy to every WebView simultaneously
- [x] Fallback chain: VPN tunnel → local proxy → direct SOCKS5 → direct connection

---

## Stage 2 — On-Device Local Proxy Server (Wireproxy Concept) ✅ COMPLETE

**What changed:**
- [x] `ProxyHealthMonitor` — periodic upstream SOCKS5 health checks with configurable intervals, auto-failover when upstream dies after N consecutive failures
- [x] `ProxyConnectionPool` — connection pooling with idle timeout, TTL eviction, hit/miss tracking, and automatic cleanup of stale connections
- [x] Enhanced `LocalProxyServer` — connection limits (max 50 concurrent), per-connection tracking with target host/port/state/bytes, peak connections, error categorization (connection/handshake/relay), upload/download bandwidth split, uptime tracking, throughput calculation, health monitor integration
- [x] Enhanced `LocalProxyConnection` — connection timeout support, error type categorization, upload vs download byte tracking, per-connection state reporting to server, timeout auto-cancel
- [x] `DeviceProxyService` enhanced — auto-failover integration (triggers rotation when health monitor detects dead upstream), configurable health check interval and max failures, failover counter, settings persistence for new health/failover options
- [x] `ProxyStatusDashboardView` — real-time monitoring dashboard with server overview (uptime, throughput, peak connections), health monitor stats (latency, success rate, consecutive failures, failover count), connection pool metrics (utilization, hit rate, evictions), active connections list, error breakdown by type, bandwidth split, health log, recent hosts
- [x] Updated `DeviceNetworkSettingsView` — wireproxy branding, health status inline display, error breakdown, failover count, auto-failover toggle, navigation link to Proxy Dashboard

**Features delivered:**
- Single unified proxy endpoint for the entire app (`localhost:18080`)
- Upstream proxy rotation happens transparently — change the upstream, all WebViews immediately use the new IP
- Connection pooling with keep-alive management (20 pool slots, 60s idle timeout, 5min TTL)
- Automatic health monitoring — checks upstream every 30s, auto-rotates after 3 consecutive failures
- Support for proxy chaining (local → upstream SOCKS5 → internet)
- Real-time status dashboard showing active connections, bytes transferred, upstream health, error breakdown
- Connection limits prevent resource exhaustion (max 50 concurrent)
- Per-connection timeout (30s) prevents hung connections

---

## Stage 3 — Device-Wide VPN Tunnel (NetworkExtension) ✅ COMPLETE

**What changed:**
- [x] Enhanced `VPNTunnelManager` — auto-reconnect with exponential backoff (configurable delay, max attempts), connection statistics tracking (total connections, reconnects, errors, rotations, longest session), data in/out polling via provider messages, on-demand connect rules (WiFi + Cellular), kill switch option, connection event history with timestamps, endpoint reachability testing via UDP, rotation/failover-specific connect methods
- [x] `WireGuardTunnelService` — batch endpoint reachability testing with latency measurement, best endpoint selection (lowest latency), config validation (key lengths, port range, MTU range), WG-Quick config regeneration from parsed config, reachable count and average latency tracking
- [x] `VPNStatusDashboardView` — real-time tunnel status with uptime counter, data in/out display, connection statistics grid (connections, reconnects, errors, rotations, longest session, disconnects), auto-reconnect and on-demand toggles, endpoint testing with latency results and best endpoint highlight, connect-to-best-endpoint action, connection history log with event types (connected, disconnected, error, reconnect, rotation, failover)
- [x] Updated `DeviceNetworkSettingsView` VPN section — data in/out display when connected, VPN Dashboard navigation link, auto-reconnect toggle with attempt count, connect-on-demand toggle, reconnecting status badge in header
- [x] `DeviceProxyService` — VPN disconnect calls updated with reason tracking
- [x] Network Extension entitlement added — `com.apple.developer.networking.networkextension` with `packet-tunnel-provider` capability
- [x] App Groups entitlement maintained for data sharing between app and extension

**Features delivered:**
- True device-wide VPN via `NETunnelProviderManager` — when active, ALL traffic routes through WireGuard tunnel
- Auto-reconnect with exponential backoff — retries up to 3 times with increasing delay on disconnect
- Connect-on-demand rules — auto-connect on WiFi and Cellular network changes
- Connection statistics — tracks total connections, reconnects, errors, rotations, longest session duration
- Data transfer monitoring — polls tunnel extension for bytes in/out
- Endpoint reachability testing — tests all WireGuard endpoints via UDP with latency measurement
- Best endpoint selection — automatically connects to the lowest-latency reachable endpoint
- Config validation — validates WireGuard config keys, ports, MTU before connecting
- Connection event history — logs every connect, disconnect, error, reconnect, rotation, failover event
- VPN Status Dashboard — dedicated view with all tunnel metrics, endpoint testing, and history
- Rotation and failover support — dedicated methods for rotation (scheduled) and failover (upstream dead) connects
- Simulator detection — shows placeholder message on simulator, full functionality on real devices
- Fallback chain: VPN tunnel → local wireproxy → direct SOCKS5 → direct connection

**Note:** The Packet Tunnel Provider extension target requires provisioning from Apple Developer portal. The app detects simulator vs real device and falls back to Stage 2 (wireproxy) or Stage 1 (direct SOCKS5) automatically.

---

## Stage 4 — WireGuard Crypto Foundation + Noise Handshake + Encrypted Transport ✅ COMPLETE

**What changed:**
- [x] `Blake2s` — pure Swift BLAKE2s hash implementation per RFC 7693, 32-byte output, keyed hash support, no external dependencies
- [x] `WireGuardCrypto` — HMAC-BLAKE2s, KDF1/KDF2/KDF3 (WireGuard's custom key derivation), MAC computation (16-byte), TAI64N timestamp generation, Curve25519 DH via CryptoKit, ChaCha20-Poly1305 AEAD encrypt/decrypt, ephemeral keypair generation, base64 key parsing, hash mixing, WireGuard construction/identifier constants
- [x] `NoiseHandshake` — full Noise_IKpsk2 handshake initiator: builds 148-byte Message 1 (ephemeral DH, encrypted static key, encrypted TAI64N timestamp, mac1/mac2), parses 92-byte Message 2 (responder ephemeral, AEAD verification, PSK mixing), derives transport session keys (sending_key, receiving_key, sender_index, receiver_index)
- [x] `WireGuardTransport` — WireGuard session lifecycle manager: UDP connection via NWConnection, handshake initiation and response parsing, encrypted transport packets (type 4) with counter-based nonces, bidirectional packet send/receive, persistent keepalive timer, 120s rekey timer, cookie reply handling, session statistics (packets/bytes sent/received, handshake count), anti-replay via monotonic nonce tracking

**Files created:**
- `Services/WireProxy/Crypto/Blake2s.swift` — Pure Swift BLAKE2s (RFC 7693)
- `Services/WireProxy/Crypto/WireGuardCrypto.swift` — WG-specific crypto wrappers
- `Services/WireProxy/Handshake/NoiseHandshake.swift` — Noise_IKpsk2 state machine
- `Services/WireProxy/Transport/WireGuardTransport.swift` — Encrypted UDP session

**Features delivered:**
- Pure Swift BLAKE2s hash — no Go bridge, no external C libraries, ~150 lines implementing RFC 7693
- Full WireGuard Noise_IKpsk2 handshake as initiator — generates Message 1, parses Message 2, derives transport keys
- CryptoKit integration — Curve25519 for DH, ChaCha20-Poly1305 for AEAD (hardware-accelerated on Apple silicon)
- Encrypted UDP transport — send/receive IP packets through WireGuard tunnel over UDP
- Session management — keepalive, rekey after 120s, cookie handling, connection statistics
- Configurable from existing WireGuardConfig — uses private key, peer public key, PSK, endpoint from parsed .conf files
- 100% userspace — works in simulator, no NetworkExtension required

**Remaining stages:**
- Stage 6: Full Integration, UI & Rotation (wire everything into DeviceProxyService)

---

## Stage 5 — Userspace TCP/IP Stack + WireProxy SOCKS5 Bridge ✅ COMPLETE

**What changed:**
- [x] `IPv4Packet` — full IPv4 packet parser and builder: header parsing (version, IHL, DSCP, total length, identification, flags, fragment offset, TTL, protocol, checksum, src/dst address), packet construction with automatic IP checksum, IP address string↔UInt32 conversion, protocol detection (TCP/UDP)
- [x] `TCPSegment` — TCP segment parser and builder: header parsing (src/dst port, sequence/ack numbers, data offset, flags, window size, checksum, urgent pointer), segment construction with TCP pseudo-header checksum over IPv4, flag definitions (SYN/ACK/FIN/RST/PSH/URG) as OptionSet
- [x] `TCPSessionManager` — userspace TCP state machine: full TCP lifecycle (CLOSED→SYN_SENT→ESTABLISHED→FIN_WAIT1→FIN_WAIT2→TIME_WAIT→CLOSED), per-session tracking (local seq/ack, remote window size, send/receive buffers), MSS-based segmentation (1360 byte chunks), automatic ACK generation, FIN/RST handling, retransmit counting, idle session cleanup (120s timeout), port allocation (30000-60000 range)
- [x] `TunnelDNSResolver` — DNS resolution through WireGuard tunnel: constructs DNS query packets (type A, class IN), sends as UDP over IP through tunnel, parses DNS responses (skips question section, extracts A records), 5-minute TTL cache, query timeout (5s), supports direct IP passthrough
- [x] `WireProxyBridge` — main orchestrator connecting SOCKS5 to WireGuard: manages WireGuardSession lifecycle, routes incoming decrypted IP packets to TCPSessionManager (TCP) or TunnelDNSResolver (UDP/DNS), configures from WireGuardConfig (interface address, DNS, private key, peer key, endpoint), connection tracking, statistics (sessions created/active, DNS queries, bytes up/down, connections served/failed)
- [x] `WireProxyTunnelConnection` — per-connection handler: receives SOCKS5 target from handler, resolves hostname via TunnelDNSResolver, creates TCP session through tunnel, bridges SOCKS5 client ↔ TCP session (client reads → tunnel sends, tunnel receives → client writes), connection timeout (30s), proper cleanup on close/error
- [x] `WireProxySOCKS5Handler` — SOCKS5 handshake for tunnel mode: performs SOCKS5 greeting and CONNECT request parsing (IPv4/domain/IPv6), extracts target host:port, hands off to WireProxyBridge for tunnel routing, replaces upstream SOCKS5/direct connections when wireproxy mode is active
- [x] Enhanced `LocalProxyServer` — wireproxy mode toggle: when `wireProxyMode=true`, new connections are handled by `WireProxySOCKS5Handler` instead of `LocalProxyConnection`, tunnel connection tracking alongside regular connections, `enableWireProxyMode()` method for clean mode switching
- [x] Enhanced `DeviceProxyService` — wireproxy tunnel integration: `wireProxyTunnelEnabled` setting (persisted), `syncWireProxyTunnel()` starts/stops WireProxyBridge based on active WireGuard config, `effectiveProxyConfig` returns local proxy when wireproxy tunnel is active, `isWireProxyActive`/`wireProxyStatus`/`wireProxyStats` computed properties for UI

**Files created:**
- `Services/WireProxy/TCPStack/IPPacket.swift` — IPv4 packet parser/builder with checksum
- `Services/WireProxy/TCPStack/TCPPacket.swift` — TCP segment parser/builder with pseudo-header checksum
- `Services/WireProxy/TCPStack/TCPSessionManager.swift` — Userspace TCP state machine
- `Services/WireProxy/TCPStack/TunnelDNSResolver.swift` — DNS resolution through WG tunnel
- `Services/WireProxy/WireProxyBridge.swift` — Main SOCKS5-to-WireGuard orchestrator
- `Services/WireProxy/WireProxyTunnelConnection.swift` — Per-connection tunnel handler
- `Services/WireProxy/WireProxySOCKS5Handler.swift` — SOCKS5 handshake for tunnel mode

**Files modified:**
- `Services/LocalProxyServer.swift` — Added wireproxy mode, tunnel connection tracking
- `Services/DeviceProxyService.swift` — Added wireproxy tunnel enable/disable, bridge integration

**Features delivered:**
- Pure Swift userspace TCP/IP stack — parses and constructs IPv4 + TCP packets without any system networking
- Full TCP state machine — SYN→SYN-ACK→ESTABLISHED→FIN handshake, data transfer with ACK, RST support
- MSS segmentation — breaks large writes into 1360-byte TCP segments for tunnel MTU compatibility
- DNS through tunnel — hostname resolution via UDP DNS queries sent through the WireGuard tunnel, with 5-min cache
- SOCKS5-to-WireGuard bridge — accepts SOCKS5 CONNECT requests, resolves hostnames, establishes virtual TCP connections through the encrypted WG tunnel, relays data bidirectionally
- Seamless mode switching — LocalProxyServer transparently switches between direct/upstream SOCKS5 and wireproxy tunnel mode
- DeviceProxyService integration — `wireProxyTunnelEnabled` toggle activates the full stack: WG handshake → tunnel established → SOCKS5 server routes through tunnel
- 100% userspace, works in simulator — no NetworkExtension, no kernel TUN device, pure Swift
- Fallback chain: WireProxy tunnel → VPN tunnel → local proxy → direct SOCKS5 → direct connection

---

## Summary

| Stage | What It Does | Works In Simulator? | Status |
|-------|-------------|-------------------|--------|
| 1 | Fix SOCKS5 → WebView routing with proper iOS API | ✅ Yes | ✅ Complete |
| 2 | Local proxy server (wireproxy) for unified app-wide routing | ✅ Yes | ✅ Complete |
| 3 | Device-wide VPN tunnel via NetworkExtension | ❌ Real device only | ✅ Complete |
| 4 | WireGuard crypto + Noise handshake + encrypted UDP transport | ✅ Yes | ✅ Complete |
| 5 | Userspace TCP/IP stack + WireProxy SOCKS5 bridge | ✅ Yes | ✅ Complete |
| 6 | Full integration, UI & rotation | ✅ Yes | Pending |

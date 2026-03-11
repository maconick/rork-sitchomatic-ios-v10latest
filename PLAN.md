# Combine WireGuard and WireProxy into a single unified mode

## What's changing

WireGuard mode and WireProxy are doing the same thing — tunneling traffic through WireGuard configs. The current setup has two separate toggles and duplicate code paths that make things confusing and fragile. This plan merges them into one clean "WireGuard" mode that always uses WireProxy (the userspace tunnel that actually works).

### Changes

**1. Remove the separate VPN Tunnel toggle**
- [x] The `wireProxyTunnelEnabled` toggle becomes the default behavior when WireGuard mode is active — no separate toggle needed
- [x] All WireGuard traffic will use WireProxy as the single tunnel mechanism

**2. Simplify DeviceProxyService**
- [x] When WireGuard mode is active and a WG config is selected, WireProxy starts automatically
- [x] No more choosing between "WireProxy tunnel" vs "VPN tunnel" — it's just "WireGuard" and it uses WireProxy under the hood
- [x] The WireProxy dashboard, stats, reconnect, and rotation features all stay as-is
- [x] Added `stopWireProxy()` method for manual tunnel stop from dashboard

**3. Simplify NetworkSessionFactory**
- [x] WireProxy is always the mechanism for WireGuard configs
- [x] When `.wireGuardDNS` config is resolved, it routes through WireProxy's local SOCKS5 proxy
- [x] Fallback to SOCKS5 proxies still works if WireProxy fails to connect

**4. Clean up the UI**
- [x] Device Network Settings: Removed the separate "WireGuard Tunnel" section
- [x] WireGuard Tunnel dashboard link moved into Local Proxy section (shows when WG is active)
- [x] One toggle: WireGuard mode on/off via Connection Mode picker. When on, WireProxy starts. When off, it stops.

**5. Keep VPNTunnelManager as infrastructure**
- [x] The VPNTunnelManager code stays in the codebase (used for endpoint reachability testing)
- [x] It just won't be used as a traffic routing mechanism anymore

### Files changed
- `Services/DeviceProxyService.swift` — Removed `wireProxyTunnelEnabled`, added `stopWireProxy()`, WireProxy auto-starts for WG configs
- `Views/DeviceNetworkSettingsView.swift` — Removed `wireGuardTunnelSection`, added WG dashboard link in local proxy section
- `Views/WireProxyDashboardView.swift` — Updated stop/start actions to use `stopWireProxy()`/`reconnectWireProxy()`
- `Services/DefaultSettingsService.swift` — Removed `wireProxyTunnelEnabled = true` from defaults
- `Services/SuperTestService.swift` — Removed `wireProxyTunnelEnabled` check

---

# Profile Separation — Nick / Poli

## What's changing

Previously all proxy configs (SOCKS5, WireGuard, OpenVPN) were shared globally. If Nick and Poli both used the app, they'd step on each other's configs and private keys. This update creates full profile isolation so each person has their own config pool and keys.

### Changes

**1. Removed duplicate config manager files**
- [x] Deleted `WGConfigManager.swift` — thin wrapper over ProxyRotationService, not needed
- [x] Deleted `OVPNConfigManager.swift` — thin wrapper over ProxyRotationService, not needed
- [x] Updated `ServiceContainer.swift` — removed `wgManager` and `ovpnManager` properties

**2. Profile-scoped storage keys in ProxyRotationService**
- [x] All UserDefaults keys now include the active profile prefix (e.g. `nick_socks5_proxies_joe_v2`, `poli_wireguard_configs_joe_v1`)
- [x] Added `activeProfilePrefix` computed property that reads from `nordvpn_key_profile_v1`
- [x] Added `reloadForActiveProfile()` method that reloads all proxy/VPN/WG configs from profile-scoped keys
- [x] Added migration from old unprefixed keys → nick profile keys (runs once)

**3. Profile switch triggers full reload**
- [x] `NordVPNService.switchProfile()` now calls `ProxyRotationService.shared.reloadForActiveProfile()` and `DeviceProxyService.shared.handleProfileSwitch()`
- [x] `DeviceProxyService.handleProfileSwitch()` stops WireProxy, re-rotates to new profile's configs
- [x] Rotation indexes reset on profile switch so configs start fresh

**4. Nick/Poli toggle moved to Main Menu**
- [x] Added prominent profile switcher capsule at the top of `MainMenuView`
- [x] Nick = blue/cyan gradient, Poli = purple/pink gradient
- [x] Haptic feedback on switch
- [x] Removed the segmented picker from `DeviceNetworkSettingsView` (now read-only badge)

**5. NordLynx config generator uses profile-scoped private key**
- [x] `NordLynxConfigGeneratorService.activePrivateKey` reads profile-specific key first, falls back to legacy

### What's isolated per profile
| Data | Storage Key Pattern |
|------|--------------------|
| SOCKS5 proxies (joe) | `{nick\|poli}_socks5_proxies_joe_v2` |
| SOCKS5 proxies (ignition) | `{nick\|poli}_socks5_proxies_ignition_v1` |
| SOCKS5 proxies (ppsr) | `{nick\|poli}_socks5_proxies_ppsr_v1` |
| OpenVPN configs (joe) | `{nick\|poli}_openvpn_configs_joe_v1` |
| OpenVPN configs (ignition) | `{nick\|poli}_openvpn_configs_ignition_v1` |
| OpenVPN configs (ppsr) | `{nick\|poli}_openvpn_configs_ppsr_v1` |
| WireGuard configs (joe) | `{nick\|poli}_wireguard_configs_joe_v1` |
| WireGuard configs (ignition) | `{nick\|poli}_wireguard_configs_ignition_v1` |
| WireGuard configs (ppsr) | `{nick\|poli}_wireguard_configs_ppsr_v1` |
| NordVPN access key | Hardcoded per profile in `NordVPNKeyStore` |
| NordVPN private key | `nordvpn_{nick\|poli}_private_key_v1` |

### Files changed
- `Services/WGConfigManager.swift` — **DELETED**
- `Services/OVPNConfigManager.swift` — **DELETED**
- `Services/ServiceContainer.swift` — Removed wgManager/ovpnManager
- `Services/ProxyRotationService.swift` — Profile-scoped storage keys, migration, `reloadForActiveProfile()`
- `Services/NordVPNService.swift` — `switchProfile()` triggers full reload of proxy configs + device proxy
- `Services/DeviceProxyService.swift` — Added `handleProfileSwitch()` for clean re-rotation
- `Services/NordLynxConfigGeneratorService.swift` — Profile-scoped private key lookup
- `Views/MainMenuView.swift` — Added profile switcher capsule at top
- `Views/DeviceNetworkSettingsView.swift` — Removed profile picker, read-only badge remains

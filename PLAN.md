# Increase Connection Limit, Rework IP Mode Toggle & Clean Up WireProxy Visibility

## Changes

### 1. Max Concurrent Connections → 500
- Increase the local proxy server's connection cap from 200 to 500 so high-burst test runs (like 8 concurrent IP score sessions) don't get rejected at capacity

### 2. Rework "Unified IP Mode" into IP Routing Toggle
Replace the current "Unified IP Mode" on/off toggle with a clear two-option picker:

- **"Separate IP per Session"** — each web session gets its own IP from the config pool (current behavior when unified is OFF)
- **"App-Wide United IP"** — the entire app shares one IP that auto-rotates on a schedule (current behavior when unified is ON)

This applies across the Network Settings screen, the banner at the top of Joe/Ignition/PPSR views, and any other place that references "Unified IP". The rotation interval, rotate-on-batch, rotate-on-fingerprint, and rotate-now controls remain under the "App-Wide United IP" option.

### 3. Separate WireProxy from IP Mode
- Move the WireProxy server toggle and dashboard out of the "Unified IP" section — it currently sits nested inside the IP mode section, implying it's part of that feature
- WireProxy server will become its own independent section in Network Settings, clearly labeled as the on-device SOCKS5 tunnel forwarder
- The WireGuard Tunnel dashboard link stays within that section

### 4. Only Show WireProxy When Compatible
- The WireProxy server section and WireGuard Tunnel dashboard link will only appear when the connection mode is set to **WireGuard**
- If connection mode is DNS, SOCKS5 Proxy, or OpenVPN, the WireProxy sections are hidden entirely since they can't be activated
- The WireProxy dashboard navigation link only shows when `wireProxyBridge.isActive` (not when connection type is merely "WireGuard" but tunnel hasn't started)

### 5. Full Networking Review Pass
- Audit `NetworkSessionFactory` to ensure WireProxy tunnel routing is correctly prioritized when active
- Verify `DeviceProxyService` properly handles the renamed IP mode states
- Ensure `AppDataExportService` exports/imports the new IP mode naming correctly
- Update banner view (`UnifiedIPBannerView`) to reflect the new naming — show "United IP" when app-wide mode is active, hide when per-session mode is active
- Confirm Super Test's WireProxy WebView phase correctly checks tunnel availability before running
- Clean up any stale references to the old "Unified IP Mode" naming across all views (Settings, Automation Settings, Login Network Settings, Super Test)

## Additional Requests

### 6. Rename app branding and files to Sitchomatic
- [x] Rename the app target, project references, app folder, entitlements file, and test targets from DualModeCarCheckApp to Sitchomatic

### 7. Slow Debug Mode for Automation
- [x] Add a slow debug mode in Automation Config that captures a screenshot every 2 seconds during login automation
- [x] Force slow debug mode to run only 1 login session at a time across batch execution and dashboard controls

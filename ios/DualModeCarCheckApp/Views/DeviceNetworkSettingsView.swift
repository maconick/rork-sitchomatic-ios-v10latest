import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum FileImportType {
    case vpn, wireGuard
}

struct DeviceNetworkSettingsView: View {
    @State private var showDNSManager: Bool = false
    @State private var showProxyImport: Bool = false
    @State private var proxyBulkText: String = ""
    @State private var proxyImportReport: ProxyRotationService.ImportReport?
    @State private var isTestingProxies: Bool = false
    @State private var activeFileImportType: FileImportType?
    @State private var isTestingVPNConfigs: Bool = false
    @State private var isTestingWGConfigs: Bool = false

    private let proxyService = ProxyRotationService.shared
    private let nordService = NordVPNService.shared
    private let logger = DebugLogger.shared

    var body: some View {
        List {
            deviceWideBanner
            connectionModeSection
            ignitionRegionSection
            nordVPNSection
            endpointConfigSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network Settings")
        .sheet(isPresented: $showDNSManager) { dnsManagerSheet }
        .sheet(isPresented: $showProxyImport) { proxyImportSheet }
        .fileImporter(
            isPresented: Binding(
                get: { activeFileImportType != nil },
                set: { if !$0 { activeFileImportType = nil } }
            ),
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: true
        ) { result in
            switch activeFileImportType {
            case .vpn: handleVPNFileImport(result)
            case .wireGuard: handleWGFileImport(result)
            case .none: break
            }
        }
    }

    private func log(_ message: String, level: DebugLogLevel = .info) {
        logger.log(message, category: .network, level: level)
    }

    // MARK: - Device Wide Banner

    private var deviceWideBanner: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device-Wide Network")
                        .font(.subheadline.bold())
                    Text("Applies to Joe Fortune, Ignition & PPSR")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(proxyService.unifiedConnectionMode.label)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(modeColor)
                    Text(proxyService.networkRegion.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(modeColor.opacity(0.08))
                .clipShape(.rect(cornerRadius: 8))
            }
        } footer: {
            Text("All network configurations are shared across every mode in this app. Changing settings here affects Joe Fortune, Ignition, and PPSR simultaneously.")
        }
    }

    // MARK: - Connection Mode

    private var connectionModeSection: some View {
        Section {
            Picker(selection: Binding(
                get: { proxyService.unifiedConnectionMode },
                set: { proxyService.setUnifiedConnectionMode($0) }
            )) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.blue)
                    Text("Connection Mode")
                }
            }
            .pickerStyle(.menu)
            .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.unifiedConnectionMode)

            HStack(spacing: 10) {
                Image(systemName: proxyService.unifiedConnectionMode.icon)
                    .foregroundStyle(modeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Mode").font(.subheadline.bold())
                    Text("All targets use \(proxyService.unifiedConnectionMode.label)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(modeColor)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(modeColor.opacity(0.12)).clipShape(Capsule())
            }
        } header: {
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                Text("Connection Mode")
                Spacer()
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(modeColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(modeColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        } footer: {
            Text("Switching modes applies globally to Joe Fortune, Ignition, and PPSR.")
        }
    }

    // MARK: - Ignition Region

    private var ignitionRegionSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: proxyService.networkRegion == .usa ? "flag.fill" : "globe.asia.australia.fill")
                    .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ignition Region").font(.body)
                    Text("Select USA or AU for Ignition proxy/VPN endpoints")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { proxyService.networkRegion },
                    set: { proxyService.networkRegion = $0 }
                )) {
                    Text("USA").tag(NetworkRegion.usa)
                    Text("AU").tag(NetworkRegion.au)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.networkRegion)
        } header: {
            Label("Ignition Region", systemImage: "globe")
        } footer: {
            Text("Only Ignition uses this region toggle. Joe Fortune and PPSR share the same configs regardless of region.")
        }
    }

    // MARK: - NordVPN

    private var nordVPNSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "shield.checkered").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NordVPN Integration").font(.body)
                    Text("Profile: \(nordService.activeKeyProfile.rawValue)")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                if nordService.hasPrivateKey {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                }
            }

            Picker(selection: Binding(
                get: { nordService.activeKeyProfile },
                set: { nordService.switchProfile($0) }
            )) {
                ForEach(NordKeyProfile.allCases, id: \.self) { profile in
                    Text(profile.rawValue).tag(profile)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill").foregroundStyle(.indigo)
                    Text("Access Key Profile")
                }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.impact(weight: .medium), trigger: nordService.activeKeyProfile)

            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Key").font(.caption.bold())
                    Text(String(nordService.accessKey.prefix(12)) + "...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(nordService.activeKeyProfile.rawValue)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
            }

            if !nordService.hasPrivateKey {
                Button {
                    Task { await nordService.fetchPrivateKey() }
                } label: {
                    HStack {
                        if nordService.isLoadingKey { ProgressView().controlSize(.small) }
                        Label("Fetch WireGuard Private Key", systemImage: "key.fill")
                    }
                }
                .disabled(nordService.isLoadingKey)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private Key").font(.caption.bold())
                        Text(String(nordService.privateKey.prefix(12)) + "...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Ready").font(.caption2.bold()).foregroundStyle(.green)
                }

                Button {
                    Task { await nordService.fetchPrivateKey() }
                } label: {
                    HStack {
                        if nordService.isLoadingKey { ProgressView().controlSize(.small) }
                        Label("Re-fetch Private Key", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(nordService.isLoadingKey)
            }

            Button {
                Task { await nordService.fetchRecommendedServers(limit: 10, technology: "openvpn_tcp") }
            } label: {
                HStack {
                    if nordService.isLoadingServers { ProgressView().controlSize(.small) }
                    Label("Fetch TCP Servers", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(nordService.isLoadingServers)

            if nordService.hasPrivateKey {
                Button {
                    Task { await nordService.fetchRecommendedServers(limit: 10, technology: "wireguard_udp") }
                } label: {
                    HStack {
                        if nordService.isLoadingServers { ProgressView().controlSize(.small) }
                        Label("Fetch WireGuard Servers", systemImage: "lock.fill")
                    }
                }
                .disabled(nordService.isLoadingServers)
            }

            if !nordService.recommendedServers.isEmpty {
                Button {
                    guard !nordService.isDownloadingOVPN else { return }
                    Task {
                        let result = await nordService.downloadAllTCPConfigs(for: nordService.recommendedServers, target: .joe)
                        proxyService.syncVPNConfigsAcrossTargets()
                        log("NordVPN TCP: \(result.imported) imported, \(result.failed) failed → all targets", level: result.imported > 0 ? .success : .error)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if nordService.isDownloadingOVPN {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.doc.fill").foregroundStyle(.indigo)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download All TCP .ovpn").font(.subheadline.bold())
                            Text(nordService.isDownloadingOVPN ? "Downloading \(nordService.ovpnDownloadProgress)..." : "\(nordService.recommendedServers.count) servers available")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .disabled(nordService.isDownloadingOVPN)

                if nordService.hasPrivateKey {
                    Button {
                        var imported = 0
                        for server in nordService.recommendedServers {
                            if let wg = nordService.generateWireGuardConfig(from: server) {
                                proxyService.importWGConfig(wg, for: .joe)
                                imported += 1
                            }
                        }
                        proxyService.syncWGConfigsAcrossTargets()
                        log("Generated \(imported) WireGuard configs → all targets", level: imported > 0 ? .success : .error)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Generate All WireGuard").font(.subheadline.bold())
                                Text("\(nordService.recommendedServers.count) servers → WG configs")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                ForEach(nordService.recommendedServers, id: \.id) { server in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.hostname)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let city = server.city {
                                    Text(city).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("Load: \(server.load)%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(server.load < 30 ? .green : (server.load < 70 ? .orange : .red))
                            }
                        }
                        Spacer()
                        Menu {
                            Button {
                                Task {
                                    if let config = await nordService.downloadOVPNConfig(from: server, proto: .tcp) {
                                        proxyService.importVPNConfig(config, for: .joe)
                                        proxyService.syncVPNConfigsAcrossTargets()
                                        log("Imported TCP .ovpn: \(server.hostname) → all targets", level: .success)
                                    }
                                }
                            } label: { Label("TCP .ovpn → All", systemImage: "shield.lefthalf.filled") }
                            if nordService.hasPrivateKey, server.publicKey != nil {
                                Divider()
                                Button {
                                    if let wgConfig = nordService.generateWireGuardConfig(from: server) {
                                        proxyService.importWGConfig(wgConfig, for: .joe)
                                        proxyService.syncWGConfigsAcrossTargets()
                                        log("Imported WG: \(server.hostname) → all targets", level: .success)
                                    }
                                } label: { Label("WireGuard → All", systemImage: "lock.fill") }
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                    }
                }
            }

            if nordService.isTokenExpired {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Access Token Expired")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    Text("Your NordVPN access token is no longer valid. Go to your NordVPN account dashboard → Manual Setup to generate a new one, then update it in NordLynx Access Key Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let error = nordService.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Text("NordVPN")
                Spacer()
                if nordService.isTokenExpired {
                    Text("Token Expired")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    Text(nordService.activeKeyProfile.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("Toggle between Nick and Poli access keys. Fetched servers and configs are shared across all targets. Server listing does not require authentication.")
        }
    }

    // MARK: - Endpoint Config

    @ViewBuilder
    private var endpointConfigSection: some View {
        switch proxyService.unifiedConnectionMode {
        case .proxy: proxySection
        case .openvpn: openVPNSection
        case .wireguard: wireGuardSection
        case .dns: dnsSection
        }
    }

    private var proxySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOCKS5 Proxies").font(.body)
                    Text("\(proxyService.unifiedProxies.count) proxies loaded")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                proxyBadge
            }

            Button { showProxyImport = true } label: {
                Label("Import Proxies", systemImage: "doc.on.clipboard.fill")
            }

            if !proxyService.unifiedProxies.isEmpty {
                Button {
                    guard !isTestingProxies else { return }
                    isTestingProxies = true
                    Task {
                        log("Testing all \(proxyService.unifiedProxies.count) proxies...")
                        await proxyService.testAllUnifiedProxies()
                        let working = proxyService.unifiedProxies.filter(\.isWorking).count
                        log("Proxy test: \(working)/\(proxyService.unifiedProxies.count) working", level: .success)
                        isTestingProxies = false
                    }
                } label: {
                    HStack {
                        Label("Test All Proxies", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingProxies { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingProxies)

                Button {
                    let exported = proxyService.exportProxies(target: .joe)
                    UIPasteboard.general.string = exported
                    log("Exported \(proxyService.unifiedProxies.count) proxies to clipboard", level: .success)
                } label: {
                    Label("Export to Clipboard", systemImage: "doc.on.doc")
                }

                let deadCount = proxyService.unifiedProxies.filter({ !$0.isWorking && $0.lastTested != nil }).count
                if deadCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeDead(forIgnition: false)
                        proxyService.syncProxiesAcrossTargets()
                        log("Removed \(deadCount) dead proxies")
                    } label: {
                        Label("Remove \(deadCount) Dead", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedProxies()
                    log("Cleared all proxies")
                } label: {
                    Label("Clear All Proxies", systemImage: "trash")
                }
            }
        } header: {
            Label("SOCKS5 Proxies", systemImage: "network")
        }
    }

    @ViewBuilder
    private var proxyBadge: some View {
        let proxies = proxyService.unifiedProxies
        if !proxies.isEmpty {
            HStack(spacing: 4) {
                let working = proxies.filter(\.isWorking).count
                if working > 0 {
                    Text("\(working) ok")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
                let dead = proxies.filter({ !$0.isWorking && $0.lastTested != nil }).count
                if dead > 0 {
                    Text("\(dead) dead")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(.tertiarySystemFill)).clipShape(Capsule())
        }
    }

    private var openVPNSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenVPN Configs").font(.body)
                    Text("\(proxyService.unifiedVPNConfigs.count) configs loaded")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                let enabledCount = proxyService.unifiedVPNConfigs.filter(\.isEnabled).count
                if enabledCount > 0 {
                    Text("\(enabledCount) active")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
                }
            }

            Button { activeFileImportType = .vpn } label: {
                Label("Import .ovpn Files", systemImage: "doc.badge.plus")
            }

            if !proxyService.unifiedVPNConfigs.isEmpty {
                Button {
                    guard !isTestingVPNConfigs else { return }
                    isTestingVPNConfigs = true
                    Task {
                        log("Testing \(proxyService.unifiedVPNConfigs.count) OpenVPN configs...")
                        await proxyService.testAllUnifiedVPNConfigs()
                        let reachable = proxyService.unifiedVPNConfigs.filter(\.isReachable).count
                        log("OpenVPN test: \(reachable)/\(proxyService.unifiedVPNConfigs.count) reachable", level: .success)
                        isTestingVPNConfigs = false
                    }
                } label: {
                    HStack {
                        Label("Test All OpenVPN", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingVPNConfigs { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingVPNConfigs)

                ForEach(proxyService.unifiedVPNConfigs) { vpn in
                    HStack(spacing: 8) {
                        Image(systemName: vpn.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vpn.isEnabled ? .indigo : .secondary)
                            .onTapGesture {
                                proxyService.toggleVPNConfig(vpn, target: .joe, enabled: !vpn.isEnabled)
                                proxyService.syncVPNConfigsAcrossTargets()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vpn.fileName)
                                .font(.system(.caption, design: .monospaced, weight: .medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(vpn.displayString)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(vpn.statusLabel)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(vpn.isReachable ? .green : (vpn.lastTested != nil ? .red : .gray))
                                if let latency = vpn.lastLatencyMs {
                                    Text("\(latency)ms")
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            proxyService.removeVPNConfig(vpn, target: .joe)
                            proxyService.syncVPNConfigsAcrossTargets()
                            log("Removed VPN: \(vpn.fileName)")
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                let unreachableCount = proxyService.unifiedVPNConfigs.filter({ !$0.isReachable && $0.lastTested != nil }).count
                if unreachableCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeUnreachableVPNConfigs(target: .joe)
                        proxyService.syncVPNConfigsAcrossTargets()
                        log("Removed \(unreachableCount) unreachable OpenVPN configs")
                    } label: {
                        Label("Remove \(unreachableCount) Unreachable", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedVPNConfigs()
                    log("Cleared all OpenVPN configs")
                } label: {
                    Label("Clear All Configs", systemImage: "trash")
                }
            }
        } header: {
            Label("OpenVPN", systemImage: "shield.lefthalf.filled")
        }
    }

    private var wireGuardSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WireGuard Configs").font(.body)
                    Text("\(proxyService.unifiedWGConfigs.count) configs loaded")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                let enabledCount = proxyService.unifiedWGConfigs.filter(\.isEnabled).count
                if enabledCount > 0 {
                    Text("\(enabledCount) active")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12)).clipShape(Capsule())
                }
            }

            Button { activeFileImportType = .wireGuard } label: {
                Label("Import .conf Files", systemImage: "doc.badge.plus")
            }

            if !proxyService.unifiedWGConfigs.isEmpty {
                Button {
                    guard !isTestingWGConfigs else { return }
                    isTestingWGConfigs = true
                    Task {
                        log("Testing \(proxyService.unifiedWGConfigs.count) WireGuard configs...")
                        await proxyService.testAllUnifiedWGConfigs()
                        let reachable = proxyService.unifiedWGConfigs.filter(\.isReachable).count
                        log("WireGuard test: \(reachable)/\(proxyService.unifiedWGConfigs.count) reachable", level: .success)
                        isTestingWGConfigs = false
                    }
                } label: {
                    HStack {
                        Label("Test All WireGuard", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingWGConfigs { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingWGConfigs)

                ForEach(proxyService.unifiedWGConfigs) { wg in
                    HStack(spacing: 8) {
                        Image(systemName: wg.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(wg.isEnabled ? .purple : .secondary)
                            .onTapGesture {
                                proxyService.toggleWGConfig(wg, target: .joe, enabled: !wg.isEnabled)
                                proxyService.syncWGConfigsAcrossTargets()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wg.fileName)
                                .font(.system(.caption, design: .monospaced, weight: .medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(wg.displayString)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(wg.statusLabel)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(wg.isReachable ? .green : (wg.lastTested != nil ? .red : .gray))
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            proxyService.removeWGConfig(wg, target: .joe)
                            proxyService.syncWGConfigsAcrossTargets()
                            log("Removed WireGuard: \(wg.fileName)")
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                let unreachableWGCount = proxyService.unifiedWGConfigs.filter({ !$0.isReachable && $0.lastTested != nil }).count
                if unreachableWGCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeUnreachableWGConfigs(target: .joe)
                        proxyService.syncWGConfigsAcrossTargets()
                        log("Removed \(unreachableWGCount) unreachable WireGuard configs")
                    } label: {
                        Label("Remove \(unreachableWGCount) Unreachable", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedWGConfigs()
                    log("Cleared all WireGuard configs")
                } label: {
                    Label("Clear All Configs", systemImage: "trash")
                }
            }
        } header: {
            Label("WireGuard", systemImage: "lock.trianglebadge.exclamationmark.fill")
        }
    }

    private var dnsSection: some View {
        Section {
            let enabled = PPSRDoHService.shared.managedProviders.filter(\.isEnabled).count
            let total = PPSRDoHService.shared.managedProviders.count
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DoH DNS Rotation").font(.body)
                    Text("\(enabled)/\(total) providers enabled · rotates each request")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }

            Button { showDNSManager = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundStyle(.cyan)
                    Text("Manage DNS Servers")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("DNS-over-HTTPS", systemImage: "lock.shield.fill")
        } footer: {
            Text("DNS-over-HTTPS rotation is shared across all targets.")
        }
    }

    // MARK: - Helpers

    private var modeColor: Color {
        switch proxyService.unifiedConnectionMode {
        case .proxy: .blue
        case .openvpn: .indigo
        case .wireguard: .purple
        case .dns: .cyan
        }
    }

    // MARK: - File Handlers

    private func handleVPNFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported = 0
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url),
                   let content = String(data: data, encoding: .utf8) {
                    let fileName = url.lastPathComponent
                    if let config = OpenVPNConfig.parse(fileName: fileName, content: content) {
                        proxyService.importUnifiedVPNConfig(config)
                        imported += 1
                    } else {
                        log("Failed to parse: \(fileName)", level: .warning)
                    }
                }
            }
            if imported > 0 {
                log("Imported \(imported) OpenVPN config(s) → all targets", level: .success)
            }
        case .failure(let error):
            log("VPN import error: \(error.localizedDescription)", level: .error)
        }
    }

    private func handleWGFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var parsed: [WireGuardConfig] = []
            var failedFiles: [String] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    failedFiles.append(url.lastPathComponent)
                    continue
                }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url),
                   let content = String(data: data, encoding: .utf8) {
                    let fileName = url.lastPathComponent
                    let configs = WireGuardConfig.parseMultiple(fileName: fileName, content: content)
                    if configs.isEmpty {
                        if let single = WireGuardConfig.parse(fileName: fileName, content: content) {
                            parsed.append(single)
                        } else {
                            failedFiles.append(fileName)
                        }
                    } else {
                        parsed.append(contentsOf: configs)
                    }
                } else {
                    failedFiles.append(url.lastPathComponent)
                }
            }
            if !parsed.isEmpty {
                let report = proxyService.importUnifiedWGConfigs(parsed)
                log("WireGuard import: \(report.added) added, \(report.duplicates) duplicates → all targets", level: .success)
            }
            for name in failedFiles {
                log("Failed to parse WireGuard: \(name)", level: .warning)
            }
        case .failure(let error):
            log("WireGuard import error: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Sheets

    private var proxyImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(.blue).frame(width: 10, height: 10)
                        Text("Import SOCKS5 Proxies").font(.headline)
                    }
                    Text("Imported proxies are synced across all targets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            proxyBulkText = clipboard
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                    let lineCount = proxyBulkText.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count
                    if lineCount > 0 {
                        Text("\(lineCount) lines").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $proxyBulkText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if proxyBulkText.isEmpty {
                            Text("Paste SOCKS5 proxies here...\n\n127.0.0.1:1080\nuser:pass@proxy.com:9050")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                if let report = proxyImportReport {
                    HStack(spacing: 12) {
                        if report.added > 0 {
                            Label("\(report.added) added", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.green)
                        }
                        if report.duplicates > 0 {
                            Label("\(report.duplicates) duplicates", systemImage: "arrow.triangle.2.circlepath").font(.caption.bold()).foregroundStyle(.orange)
                        }
                        if !report.failed.isEmpty {
                            Label("\(report.failed.count) failed", systemImage: "xmark.circle.fill").font(.caption.bold()).foregroundStyle(.red)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import Proxies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showProxyImport = false
                        proxyBulkText = ""
                        proxyImportReport = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let report = proxyService.importUnifiedProxy(proxyBulkText)
                        proxyImportReport = report
                        if report.added > 0 {
                            log("Imported \(report.added) SOCKS5 proxies → all targets", level: .success)
                        }
                        proxyBulkText = ""
                        if report.failed.isEmpty && report.added > 0 {
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                showProxyImport = false
                                proxyImportReport = nil
                            }
                        }
                    }
                    .disabled(proxyBulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    @State private var dnsImportText: String = ""
    @State private var showDNSImport: Bool = false
    @State private var newDNSName: String = ""
    @State private var newDNSURL: String = ""

    private var dnsManagerSheet: some View {
        NavigationStack {
            List {
                if showDNSImport {
                    Section("Import DNS Servers") {
                        Text("One per line. Format: Name|URL or just URL")
                            .font(.caption2).foregroundStyle(.secondary)

                        TextEditor(text: $dnsImportText)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                            .frame(minHeight: 80)
                            .overlay(alignment: .topLeading) {
                                if dnsImportText.isEmpty {
                                    Text("Custom|https://dns.example.com/dns-query\nhttps://dns.other.com/dns-query")
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.quaternary)
                                        .padding(.horizontal, 12).padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }

                        HStack {
                            Button {
                                if let clip = UIPasteboard.general.string { dnsImportText = clip }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard").font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            Button {
                                let result = PPSRDoHService.shared.bulkImportProviders(dnsImportText)
                                log("DNS import: \(result.added) added, \(result.duplicates) dupes, \(result.invalid) invalid", level: result.added > 0 ? .success : .warning)
                                dnsImportText = ""
                                if result.added > 0 { withAnimation(.snappy) { showDNSImport = false } }
                            } label: {
                                Label("Import", systemImage: "arrow.down.doc.fill").font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent).tint(.cyan)
                            .disabled(dnsImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Section("Add Single Server") {
                        TextField("Name", text: $newDNSName)
                            .font(.system(.body, design: .monospaced))
                        TextField("https://dns.example.com/dns-query", text: $newDNSURL)
                            .font(.system(.callout, design: .monospaced))
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            if PPSRDoHService.shared.addProvider(name: newDNSName, url: newDNSURL) {
                                log("Added DNS provider: \(newDNSName)", level: .success)
                                newDNSName = ""
                                newDNSURL = ""
                            }
                        } label: {
                            Label("Add Server", systemImage: "plus.circle.fill")
                        }
                        .disabled(newDNSName.trimmingCharacters(in: .whitespaces).isEmpty || newDNSURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                let enabled = PPSRDoHService.shared.managedProviders.filter(\.isEnabled).count
                Section {
                    ForEach(PPSRDoHService.shared.managedProviders) { provider in
                        HStack(spacing: 10) {
                            Button {
                                PPSRDoHService.shared.toggleProvider(id: provider.id, enabled: !provider.isEnabled)
                            } label: {
                                Image(systemName: provider.isEnabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(provider.isEnabled ? .cyan : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.name).font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    if provider.isDefault {
                                        Text("DEFAULT")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.cyan.opacity(0.7))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.cyan.opacity(0.1)).clipShape(Capsule())
                                    }
                                }
                                Text(provider.url.replacingOccurrences(of: "https://", with: ""))
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                PPSRDoHService.shared.deleteProvider(id: provider.id)
                                log("Deleted DNS provider: \(provider.name)")
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("DNS Servers (\(enabled)/\(PPSRDoHService.shared.managedProviders.count))")
                }

                Section {
                    Button {
                        withAnimation(.snappy) { showDNSImport.toggle() }
                    } label: {
                        Label(showDNSImport ? "Hide Import" : "Import / Add Servers", systemImage: "plus.circle.fill")
                    }
                    Button {
                        PPSRDoHService.shared.enableAll()
                        log("Enabled all DNS providers", level: .success)
                    } label: {
                        Label("Enable All", systemImage: "checkmark.circle")
                    }
                    Button {
                        PPSRDoHService.shared.resetToDefaults()
                        log("Reset DNS providers to defaults", level: .success)
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.uturn.backward")
                    }
                } header: {
                    Text("Actions")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("DNS Manager").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showDNSManager = false } }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

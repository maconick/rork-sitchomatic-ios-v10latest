import SwiftUI

struct ProxyManagerView: View {
    @State private var vm = ProxyManagerViewModel()
    @State private var showNewSetSheet: Bool = false
    @State private var newSetName: String = ""
    @State private var newSetType: ProxySetType = .socks5

    var body: some View {
        List {
            overviewSection
            if vm.canUseOnePerSet {
                sessionRoutingSection
            }
            proxySetsSection
            if !vm.proxySets.isEmpty {
                quickStatsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Proxy Manager")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newSetName = ""
                    newSetType = .socks5
                    showNewSetSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                }
            }
        }
        .sheet(isPresented: $showNewSetSheet) {
            newSetSheetContent
        }
    }

    private var overviewSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(vm.proxySets.count) Proxy Sets")
                        .font(.headline)
                    Text("\(vm.totalItemsCount) total servers · \(vm.activeSetsCount) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if vm.canUseOnePerSet {
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                        Text("4+ sets")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.8))
                    }
                }
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
    }

    private var sessionRoutingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { vm.useOneServerPerSet },
                set: { newValue in
                    vm.useOneServerPerSet = newValue
                }
            )) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1 Server Per Set")
                            .font(.subheadline.bold())
                        Text("Each concurrent session uses a different set")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.purple)

            if vm.useOneServerPerSet {
                let activeSets = vm.proxySets.filter(\.isActive)
                ForEach(Array(activeSets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: 10) {
                        Text("Session \(index + 1)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(sessionColor(index), in: Capsule())

                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Image(systemName: set.typeIcon)
                            .font(.caption)
                            .foregroundStyle(typeColor(set.type))

                        Text(set.name)
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        Text(set.summary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Session Routing", systemImage: "arrow.triangle.swap")
        } footer: {
            Text("When enabled, each concurrent session draws from a separate proxy set. Requires 4+ active sets.")
        }
    }

    private var proxySetsSection: some View {
        Section {
            if vm.proxySets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Proxy Sets")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to create a set and import proxies, WireGuard, or OpenVPN configs.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(vm.proxySets) { set in
                    NavigationLink {
                        ProxySetDetailView(vm: vm, setId: set.id)
                    } label: {
                        proxySetRow(set)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            vm.deleteSet(set)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            vm.toggleSetActive(set)
                        } label: {
                            Label(
                                set.isActive ? "Disable" : "Enable",
                                systemImage: set.isActive ? "pause.circle" : "play.circle"
                            )
                        }
                        .tint(set.isActive ? .orange : .green)
                    }
                }
            }
        } header: {
            Label("Proxy Sets", systemImage: "rectangle.stack.fill")
        } footer: {
            if !vm.proxySets.isEmpty {
                Text("Each set holds up to 10 items of a single type. Swipe to enable/disable or delete.")
            }
        }
    }

    private var quickStatsSection: some View {
        Section {
            let socks5Count = vm.proxySets.filter { $0.type == .socks5 }.count
            let wgCount = vm.proxySets.filter { $0.type == .wireGuard }.count
            let ovpnCount = vm.proxySets.filter { $0.type == .openVPN }.count

            HStack {
                statBadge(count: socks5Count, label: "SOCKS5", icon: "network", color: .blue)
                Spacer()
                statBadge(count: wgCount, label: "WireGuard", icon: "lock.trianglebadge.exclamationmark.fill", color: .cyan)
                Spacer()
                statBadge(count: ovpnCount, label: "OpenVPN", icon: "shield.lefthalf.filled", color: .orange)
            }
            .padding(.vertical, 4)
        } header: {
            Label("Breakdown", systemImage: "chart.bar.fill")
        }
    }

    private func proxySetRow(_ set: ProxySet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(typeColor(set.type).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: set.typeIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(typeColor(set.type))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(set.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    if !set.isActive {
                        Text("OFF")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(set.type.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(typeColor(set.type))

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(set.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if set.isFull {
                Text("FULL")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12), in: Capsule())
            } else {
                Text("\(set.items.count)/10")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statBadge(count: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                Text("\(count)")
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(.primary)
            }
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var newSetSheetContent: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Set Name", text: $newSetName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                }

                Section {
                    Picker("Type", selection: $newSetType) {
                        ForEach(ProxySetType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Connection Type")
                } footer: {
                    Text("Each set can only contain one type. You can import up to 10 items per set.")
                }
            }
            .navigationTitle("New Proxy Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewSetSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        vm.createSet(name: name, type: newSetType)
                        showNewSetSheet = false
                    }
                    .disabled(newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func typeColor(_ type: ProxySetType) -> Color {
        switch type {
        case .socks5: .blue
        case .wireGuard: .cyan
        case .openVPN: .orange
        }
    }

    private func sessionColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .orange, .green, .pink, .indigo, .cyan]
        return colors[index % colors.count]
    }
}

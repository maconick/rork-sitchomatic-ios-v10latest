import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct DualWebStackView: View {
    @State private var vm = LoginViewModel()
    @State private var initialSetupDone: Bool = false

    @State private var topProcessPool = WKProcessPool()
    @State private var bottomProcessPool = WKProcessPool()

    @State private var topIsLoading: Bool = true
    @State private var bottomIsLoading: Bool = true
    @State private var topPageTitle: String = ""
    @State private var bottomPageTitle: String = ""
    @State private var topCurrentURL: String = ""
    @State private var bottomCurrentURL: String = ""

    @State private var topWebView: WKWebView?
    @State private var bottomWebView: WKWebView?

    @State private var splitRatio: CGFloat = 0.45
    @State private var dragStartRatio: CGFloat = 0.45
    @State private var isDragging: Bool = false
    @State private var reloadTrigger: Int = 0

    @State private var showCredentialsSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var bulkText: String = ""
    @State private var showBulkImport: Bool = false
    @State private var bulkImportResult: String? = nil
    @State private var showLogSheet: Bool = false
    @State private var showAutomationSettings: Bool = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width > geo.size.height && horizontalSizeClass == .regular
            if isWide {
                landscapeLayout(geo: geo)
            } else {
                portraitLayout(geo: geo)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(.systemBackground))
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .top) {
            topToolbar
        }
        .safeAreaInset(edge: .bottom) {
            splitControlBar
        }
        .onAppear {
            if !initialSetupDone {
                initialSetupDone = true
                vm.setSiteMode(.dual)
            }
        }
        .sheet(isPresented: $showCredentialsSheet) {
            splitCredentialsSheet
        }
        .sheet(isPresented: $showImportSheet) {
            splitImportSheet
        }
        .sheet(isPresented: $showLogSheet) {
            splitLogSheet
        }
        .sheet(isPresented: $showAutomationSettings) {
            NavigationStack {
                AutomationSettingsView(vm: vm)
                    .navigationTitle("Automation Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showAutomationSettings = false }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .withBatchAlerts(
            showBatchResult: $vm.showBatchResultPopup,
            batchResult: vm.lastBatchResult,
            isRunning: $vm.isRunning,
            onDismissBatch: { vm.showBatchResultPopup = false }
        )
        .onChange(of: vm.credentials.count) { _, _ in
            vm.persistCredentials()
        }
    }

    private func portraitLayout(geo: GeometryProxy) -> some View {
        let totalHeight = geo.size.height
        let handleHeight: CGFloat = 28
        let topHeight = (totalHeight - handleHeight) * splitRatio
        let bottomHeight = (totalHeight - handleHeight) * (1.0 - splitRatio)

        return VStack(spacing: 0) {
            webPane(
                label: "JOE FORTUNE",
                icon: "suit.spade.fill",
                color: .green,
                url: URL(string: "https://joefortunepokies.win/login")!,
                processPool: topProcessPool,
                isLoading: $topIsLoading,
                pageTitle: $topPageTitle,
                currentURL: $topCurrentURL,
                webViewRef: $topWebView
            )
            .frame(height: topHeight)

            dragHandle(geo: geo, isVertical: false)
                .frame(height: handleHeight)

            webPane(
                label: "IGNITION",
                icon: "flame.fill",
                color: .orange,
                url: URL(string: "https://static.ignitioncasino.lat/?overlay=login")!,
                processPool: bottomProcessPool,
                isLoading: $bottomIsLoading,
                pageTitle: $bottomPageTitle,
                currentURL: $bottomCurrentURL,
                webViewRef: $bottomWebView
            )
            .frame(height: bottomHeight)
        }
    }

    private func landscapeLayout(geo: GeometryProxy) -> some View {
        let totalWidth = geo.size.width
        let handleWidth: CGFloat = 28
        let leftWidth = (totalWidth - handleWidth) * splitRatio
        let rightWidth = (totalWidth - handleWidth) * (1.0 - splitRatio)

        return HStack(spacing: 0) {
            webPane(
                label: "JOE FORTUNE",
                icon: "suit.spade.fill",
                color: .green,
                url: URL(string: "https://joefortunepokies.win/login")!,
                processPool: topProcessPool,
                isLoading: $topIsLoading,
                pageTitle: $topPageTitle,
                currentURL: $topCurrentURL,
                webViewRef: $topWebView
            )
            .frame(width: leftWidth)

            dragHandle(geo: geo, isVertical: true)
                .frame(width: handleWidth)

            webPane(
                label: "IGNITION",
                icon: "flame.fill",
                color: .orange,
                url: URL(string: "https://static.ignitioncasino.lat/?overlay=login")!,
                processPool: bottomProcessPool,
                isLoading: $bottomIsLoading,
                pageTitle: $bottomPageTitle,
                currentURL: $bottomCurrentURL,
                webViewRef: $bottomWebView
            )
            .frame(width: rightWidth)
        }
    }

    private func webPane(
        label: String,
        icon: String,
        color: Color,
        url: URL,
        processPool: WKProcessPool,
        isLoading: Binding<Bool>,
        pageTitle: Binding<String>,
        currentURL: Binding<String>,
        webViewRef: Binding<WKWebView?>
    ) -> some View {
        ZStack(alignment: .top) {
            SplitWebViewRepresentable(
                url: url,
                processPool: processPool,
                stealthEnabled: vm.stealthEnabled,
                automationSettings: vm.automationSettings,
                isLoading: isLoading,
                pageTitle: pageTitle,
                currentURL: currentURL,
                onWebViewCreated: { wv in
                    webViewRef.wrappedValue = wv
                }
            )
            .id("\(label)-\(reloadTrigger)")

            paneOverlayHeader(
                label: label,
                icon: icon,
                color: color,
                isLoading: isLoading.wrappedValue,
                urlHost: currentURL.wrappedValue
            )
        }
        .clipShape(.rect(cornerRadius: 0))
    }

    private func paneOverlayHeader(label: String, icon: String, color: Color, isLoading: Bool, urlHost: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isLoading)

            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            if !urlHost.isEmpty {
                Text(urlHost)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
    }

    private func dragHandle(geo: GeometryProxy, isVertical: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemBackground))

            LinearGradient(
                colors: [.green.opacity(isDragging ? 0.4 : 0.15), .orange.opacity(isDragging ? 0.4 : 0.15)],
                startPoint: isVertical ? .top : .leading,
                endPoint: isVertical ? .bottom : .trailing
            )

            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(isDragging ? 0.5 : 0.2))
                .frame(
                    width: isVertical ? 4 : 36,
                    height: isVertical ? 36 : 4
                )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        dragStartRatio = splitRatio
                        isDragging = true
                    }
                    let dimension = isVertical ? geo.size.width : geo.size.height
                    let translation = isVertical ? value.translation.width : value.translation.height
                    let delta = translation / dimension
                    splitRatio = (dragStartRatio + delta).clamped(to: 0.25...0.75)
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                        isDragging = false
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: isDragging)
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack(spacing: 8) {
            MainMenuButton()

            Spacer()

            splitCredentialBadges

            splitStealthBadge

            HStack(spacing: 4) {
                Circle()
                    .fill(topIsLoading ? .yellow : .green)
                    .frame(width: 6, height: 6)
                Circle()
                    .fill(bottomIsLoading ? .yellow : .orange)
                    .frame(width: 6, height: 6)
            }

            Button {
                showAutomationSettings = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(vm.automationSettings.trueDetectionEnabled ? "TD" : "STD")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.purple.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.purple.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                reloadBoth()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .bold))
                    Text("RELOAD")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: reloadTrigger)

            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                    splitRatio = 0.45
                }
            } label: {
                Image(systemName: "equal")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
    }

    private var splitCredentialBadges: some View {
        Button {
            showCredentialsSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("\(vm.credentials.count)")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                if vm.workingCredentials.count > 0 {
                    Text("·")
                        .foregroundStyle(.green)
                    Text("\(vm.workingCredentials.count)")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Control Bar

    private var splitControlBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            HStack(spacing: 10) {
                if vm.isRunning {
                    runningControls
                } else {
                    idleControls
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var runningControls: some View {
        Group {
            HStack(spacing: 6) {
                if vm.isPaused {
                    Button {
                        vm.resumeQueue()
                    } label: {
                        splitControlPill(icon: "play.fill", label: vm.pauseCountdown > 0 ? "RESUME \(vm.pauseCountdown)s" : "RESUME", color: .green)
                    }
                    .contentTransition(.numericText(value: Double(vm.pauseCountdown)))
                    .animation(.snappy, value: vm.pauseCountdown)
                } else {
                    Button {
                        vm.pauseQueue()
                    } label: {
                        splitControlPill(icon: "pause.fill", label: "PAUSE", color: .orange)
                    }
                }

                Button {
                    vm.stopQueue()
                } label: {
                    splitControlPill(icon: "stop.fill", label: "STOP", color: .red)
                }
                .disabled(vm.isStopping)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("\(vm.activeTestCount) active")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                }
                Text("\(vm.untestedCredentials.count) queued")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .animation(.snappy, value: vm.activeTestCount)
        }
    }

    private var idleControls: some View {
        Group {
            Button {
                showImportSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("IMPORT")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.1))
                .clipShape(Capsule())
            }

            Button {
                vm.testAllUntested()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("SPLIT TEST")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    if vm.untestedCredentials.count > 0 {
                        Text("(\(vm.untestedCredentials.count))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
            }
            .disabled(vm.untestedCredentials.isEmpty)
            .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)

            Spacer()

            Button {
                showLogSheet = true
            } label: {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(vm.credentials.count) total")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                if vm.workingCredentials.count > 0 {
                    Text("\(vm.workingCredentials.count) working")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func splitControlPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: - Credentials Sheet

    private var splitCredentialsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                splitCredentialStats
                    .padding(.horizontal)
                    .padding(.top, 8)

                if showBulkImport {
                    splitBulkImportBox
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                splitCredentialList
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Split Test Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showCredentialsSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.snappy) { showBulkImport.toggle() }
                        } label: {
                            Image(systemName: showBulkImport ? "rectangle.and.pencil.and.ellipsis" : "doc.on.clipboard")
                        }
                        Button {
                            showCredentialsSheet = false
                            showImportSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var splitCredentialStats: some View {
        HStack(spacing: 8) {
            SplitCredStatPill(value: vm.workingCredentials.count, label: "OK", color: .green)
            SplitCredStatPill(value: vm.untestedCredentials.count, label: "QUEUE", color: .secondary)
            SplitCredStatPill(value: vm.noAccCredentials.count, label: "NO ACC", color: .red)
            SplitCredStatPill(value: vm.permDisabledCredentials.count, label: "PERM", color: .red.opacity(0.7))
            SplitCredStatPill(value: vm.tempDisabledCredentials.count, label: "TEMP", color: .orange)
            SplitCredStatPill(value: vm.unsureCredentials.count, label: "???", color: .yellow)
        }
    }

    private var splitBulkImportBox: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Quick Import", systemImage: "doc.on.clipboard.fill")
                    .font(.subheadline.bold())
                Spacer()
                if let result = bulkImportResult {
                    Text(result)
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Button {
                    withAnimation(.snappy) {
                        showBulkImport = false
                        bulkText = ""
                        bulkImportResult = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $bulkText)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
                .frame(height: 100)
                .overlay(alignment: .topLeading) {
                    if bulkText.isEmpty {
                        Text("Paste credentials here...\nOne per line: user:pass")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 14).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 12) {
                Spacer()
                Button {
                    if let clipboardString = UIPasteboard.general.string, !clipboardString.isEmpty {
                        bulkText = clipboardString
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button {
                    let before = vm.credentials.count
                    vm.smartImportCredentials(bulkText)
                    let added = vm.credentials.count - before
                    withAnimation(.snappy) { bulkImportResult = "\(added) added" }
                    bulkText = ""
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.snappy) { bulkImportResult = nil }
                    }
                } label: {
                    Label("Import", systemImage: "arrow.down.doc.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(bulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var splitCredentialList: some View {
        Group {
            if vm.credentials.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 44))
                        .foregroundStyle(
                            LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .symbolEffect(.pulse.byLayer, options: .repeating)
                    Text("No Credentials")
                        .font(.title3.bold())
                    Text("Import credentials to start split testing\nacross Joe Fortune & Ignition simultaneously.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        showCredentialsSheet = false
                        showImportSheet = true
                    } label: {
                        Label("Import Credentials", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(vm.credentials) { cred in
                        SplitCredentialRow(credential: cred, vm: vm)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { vm.deleteCredential(cred) } label: { Label("Delete", systemImage: "trash") }
                                Button { vm.retestCredential(cred) } label: { Label("Retest", systemImage: "arrow.clockwise") }.tint(.cyan)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { vm.testSingleCredential(cred) } label: { Label("Test", systemImage: "play.fill") }.tint(.green)
                            }
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }

                    if vm.workingCredentials.count > 0 {
                        Section {
                            Button {
                                UIPasteboard.general.string = vm.exportWorkingCredentials()
                            } label: {
                                Label("Copy \(vm.workingCredentials.count) Working to Clipboard", systemImage: "doc.on.doc.fill")
                            }
                        } header: {
                            Text("Export")
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }

                    Section {
                        Button(role: .destructive) { vm.purgeNoAccCredentials() } label: {
                            Label("Purge No Acc (\(vm.noAccCredentials.count))", systemImage: "trash")
                        }
                        .disabled(vm.noAccCredentials.isEmpty)

                        Button(role: .destructive) { vm.purgePermDisabledCredentials() } label: {
                            Label("Purge Perm Disabled (\(vm.permDisabledCredentials.count))", systemImage: "trash")
                        }
                        .disabled(vm.permDisabledCredentials.isEmpty)

                        Button(role: .destructive) { vm.purgeUnsureCredentials() } label: {
                            Label("Purge Unsure (\(vm.unsureCredentials.count))", systemImage: "trash")
                        }
                        .disabled(vm.unsureCredentials.isEmpty)
                    } header: {
                        Text("Cleanup")
                    }
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Import Sheet

    private var splitImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Smart Import").font(.headline)
                    Text("Paste login credentials in common formats. One per line.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(["user:pass", "user;pass", "user|pass"], id: \.self) { fmt in
                            Text(fmt)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10))
                    .frame(minHeight: 180)

                HStack {
                    Button {
                        if let clipboardString = UIPasteboard.general.string, !clipboardString.isEmpty {
                            importText = clipboardString
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    Spacer()
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import for Split Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        importText = ""
                        showImportSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        vm.smartImportCredentials(importText)
                        importText = ""
                        showImportSheet = false
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    // MARK: - Log Sheet

    private var splitLogSheet: some View {
        NavigationStack {
            Group {
                if vm.globalLogs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No logs yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.globalLogs.prefix(200)) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(logLevelColor(entry.level))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Split Test Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showLogSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { vm.clearAll() }
                        .disabled(vm.globalLogs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func logLevelColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private func reloadBoth() {
        reloadTrigger += 1
    }

    private var splitStealthBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: vm.stealthEnabled ? "shield.checkered" : "shield.slash")
                .font(.system(size: 9, weight: .bold))
            if vm.automationSettings.trueDetectionEnabled {
                Text("TRUE")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
            }
            if vm.automationSettings.fingerprintSpoofing {
                Image(systemName: "fingerprint")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(vm.stealthEnabled ? .green.opacity(0.8) : .red.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(vm.stealthEnabled ? .green.opacity(0.08) : .red.opacity(0.06))
        .clipShape(Capsule())
    }
}

// MARK: - Sub-views

struct SplitCredStatPill: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(color.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }
}

struct SplitCredentialRow: View {
    let credential: LoginCredential
    let vm: LoginViewModel
    private let nordService = NordVPNService.shared
    private let proxyService = ProxyRotationService.shared

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(credential.username)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(credential.maskedPassword)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if credential.totalTests > 0 {
                        Text("\(credential.successCount)/\(credential.totalTests)")
                            .font(.caption2.bold())
                            .foregroundStyle(credential.lastTestSuccess == true ? .green : .red)
                    }
                }
                nordAssignmentLabel
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(credential.status.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                if credential.status == .testing {
                    ProgressView().controlSize(.mini).tint(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var nordAssignmentLabel: some View {
        let mode = proxyService.connectionMode(for: .joe)
        if !nordService.recommendedServers.isEmpty {
            let serverIndex = abs(credential.username.hashValue) % nordService.recommendedServers.count
            let server = nordService.recommendedServers[serverIndex]
            HStack(spacing: 4) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 8, weight: .bold))
                Text("Nord: \(server.hostname.prefix(22))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                if let country = server.country {
                    Text(country.prefix(6))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.indigo.opacity(0.5))
                }
            }
            .foregroundStyle(.indigo.opacity(0.7))
            .lineLimit(1)
        } else if mode == .proxy && !proxyService.savedProxies.isEmpty {
            let proxyIndex = abs(credential.username.hashValue) % proxyService.savedProxies.count
            let proxy = proxyService.savedProxies[proxyIndex]
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 8, weight: .bold))
                Text(proxy.displayString.prefix(28))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.orange.opacity(0.7))
            .lineLimit(1)
        }
    }

    private var statusColor: Color {
        switch credential.status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .cyan
        case .untested: .secondary
        }
    }

    private var statusIcon: String {
        switch credential.status {
        case .working: "checkmark.circle.fill"
        case .noAcc: "xmark.circle.fill"
        case .permDisabled: "lock.slash.fill"
        case .tempDisabled: "clock.badge.exclamationmark"
        case .unsure: "questionmark.circle.fill"
        case .testing: "arrow.triangle.2.circlepath"
        case .untested: "circle.dashed"
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

import SwiftUI

struct LoginDebugScreenshotsView: View {
    @Bindable var vm: LoginViewModel
    @State private var selectedScreenshot: PPSRDebugScreenshot?
    @State private var selectedAlbum: LoginScreenshotAlbum?
    @State private var viewMode: ViewMode = .albums

    private enum ViewMode: String, CaseIterable {
        case albums = "Albums"
        case all = "All"
    }

    private var albums: [LoginScreenshotAlbum] {
        let grouped = Dictionary(grouping: vm.debugScreenshots) { $0.albumKey }
        return grouped.map { key, shots in
            LoginScreenshotAlbum(
                id: key,
                credentialUsername: shots.first?.cardDisplayNumber ?? "",
                credentialId: shots.first?.cardId ?? "",
                screenshots: shots.sorted { $0.timestamp > $1.timestamp }
            )
        }.sorted { $0.latestTimestamp > $1.latestTimestamp }
    }

    var body: some View {
        Group {
            if vm.debugScreenshots.isEmpty {
                ContentUnavailableView("No Screenshots", systemImage: "photo.stack", description: Text("Enable Debug Mode and run a test to capture screenshots."))
            } else {
                VStack(spacing: 0) {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)

                    switch viewMode {
                    case .albums:
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(albums) { album in
                                    Button { selectedAlbum = album } label: { LoginAlbumCard(album: album) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal).padding(.vertical, 12)
                        }
                    case .all:
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(vm.debugScreenshots) { screenshot in
                                    Button { selectedScreenshot = screenshot } label: { LoginScreenshotCard(screenshot: screenshot) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal).padding(.vertical, 12)
                        }
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Debug Screenshots")
        .toolbar {
            if !vm.debugScreenshots.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { vm.clearDebugScreenshots() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            LoginScreenshotCorrectionSheet(screenshot: screenshot, vm: vm)
        }
        .sheet(item: $selectedAlbum) { album in
            LoginAlbumDetailSheet(album: album, vm: vm)
        }
    }
}

struct LoginScreenshotAlbum: Identifiable {
    let id: String
    let credentialUsername: String
    let credentialId: String
    let screenshots: [PPSRDebugScreenshot]

    var title: String { credentialUsername.isEmpty ? "Unknown" : credentialUsername }
    var latestTimestamp: Date { screenshots.first?.timestamp ?? .distantPast }
    var passCount: Int { screenshots.filter { $0.effectiveResult == .markedPass }.count }
    var failCount: Int { screenshots.filter { $0.effectiveResult == .markedFail }.count }
}

struct LoginAlbumCard: View {
    let album: LoginScreenshotAlbum

    var body: some View {
        VStack(spacing: 0) {
            if let firstShot = album.screenshots.first {
                Color.clear.frame(height: 140)
                    .overlay { Image(uiImage: firstShot.image).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                    .overlay(alignment: .bottomLeading) {
                        Text("\(album.screenshots.count) screenshots")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.6)).clipShape(Capsule()).padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let latest = album.screenshots.first {
                            resultBadge(for: latest)
                                .padding(8)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold)).lineLimit(1)
                HStack(spacing: 12) {
                    Label("\(album.screenshots.count) tests", systemImage: "doc.text")
                    Spacer()
                    if album.passCount > 0 {
                        HStack(spacing: 2) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("\(album.passCount)") }
                    }
                    if album.failCount > 0 {
                        HStack(spacing: 2) { Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text("\(album.failCount)") }
                    }
                }
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func resultBadge(for screenshot: PPSRDebugScreenshot) -> some View {
        Group {
            switch screenshot.effectiveResult {
            case .markedPass:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(.green)
                    .padding(4).background(.ultraThinMaterial).clipShape(Circle())
            case .markedFail:
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.red)
                    .padding(4).background(.ultraThinMaterial).clipShape(Circle())
            case .none:
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3).foregroundStyle(.orange)
                    .padding(4).background(.ultraThinMaterial).clipShape(Circle())
            }
        }
    }
}

struct LoginScreenshotCard: View {
    let screenshot: PPSRDebugScreenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 180)
                .overlay { Image(uiImage: screenshot.displayImage).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                .overlay(alignment: .topTrailing) {
                    resultIndicator.padding(8)
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(screenshot.stepName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.12)).clipShape(Capsule())
                    Spacer()
                    Text(screenshot.formattedTime).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }

                if !screenshot.note.isEmpty {
                    Text(screenshot.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                HStack(spacing: 12) {
                    Label(screenshot.cardDisplayNumber, systemImage: "person.fill")
                    if screenshot.hasUserOverride {
                        Text(screenshot.overrideLabel)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(screenshot.userOverride == .markedPass ? .green : .red)
                    }
                }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var resultIndicator: some View {
        Group {
            switch screenshot.effectiveResult {
            case .markedPass:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(.green)
                    .padding(4).background(.ultraThinMaterial).clipShape(Circle())
            case .markedFail:
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.red)
                    .padding(4).background(.ultraThinMaterial).clipShape(Circle())
            case .none:
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3).foregroundStyle(.orange)
                    .padding(4).background(.ultraThinMaterial).clipShape(Circle())
            }
        }
    }
}

struct LoginAlbumDetailSheet: View {
    let album: LoginScreenshotAlbum
    let vm: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScreenshot: PPSRDebugScreenshot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "photo.stack.fill").foregroundStyle(.green)
                            Text("Login Session").font(.headline)
                            Spacer()
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill").font(.caption).foregroundStyle(.secondary)
                            Text(album.title).font(.system(.caption, design: .monospaced, weight: .semibold))
                        }
                        Text("\(album.screenshots.count) screenshots captured").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))

                    LazyVStack(spacing: 12) {
                        ForEach(album.screenshots) { screenshot in
                            Button { selectedScreenshot = screenshot } label: { LoginScreenshotCard(screenshot: screenshot) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal).padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Album").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedScreenshot) { screenshot in LoginScreenshotCorrectionSheet(screenshot: screenshot, vm: vm) }
        }
        .presentationDetents([.large])
    }
}

struct LoginScreenshotCorrectionSheet: View {
    @Bindable var screenshot: PPSRDebugScreenshot
    let vm: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingNote: String = ""
    @State private var showConfirmCorrection: Bool = false
    @State private var showRetestConfirmation: Bool = false
    @State private var pendingOverride: UserResultOverride = .none
    @State private var showFullPage: Bool = false
    @State private var isCropMode: Bool = false
    @State private var cropStart: CGPoint = .zero
    @State private var cropEnd: CGPoint = .zero
    @State private var isDragging: Bool = false
    @State private var bannerScanResult: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    screenshotSection
                    greenBannerScanSection
                    autoDetectionInfo
                    correctionSection
                    noteSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Review Screenshot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { editingNote = screenshot.userNote }
            .alert("Correct Result", isPresented: $showConfirmCorrection) {
                Button("Confirm") { vm.correctResult(for: screenshot, override: pendingOverride) }
                Button("Cancel", role: .cancel) {}
            } message: {
                let label = pendingOverride == .markedPass ? "PASS (Working Login)" : "FAIL (Dead Login)"
                Text("Mark this credential as \(label)? This will update the credential status.")
            }
            .alert("Retest Credential", isPresented: $showRetestConfirmation) {
                Button("Add to Queue") { vm.requeueCredentialFromScreenshot(screenshot); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Add \(screenshot.cardDisplayNumber) back to the untested queue?")
            }
        }
        .presentationDetents([.large])
    }

    private var screenshotSection: some View {
        VStack(spacing: 8) {
            HStack {
                if screenshot.croppedImage != nil {
                    Picker("View", selection: $showFullPage) {
                        Text("Focus Crop").tag(false)
                        Text("Full Page").tag(true)
                    }.pickerStyle(.segmented)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { isCropMode.toggle() }
                    if !isCropMode {
                        cropStart = .zero
                        cropEnd = .zero
                    }
                } label: {
                    Label(isCropMode ? "Done Crop" : "Crop Region", systemImage: isCropMode ? "checkmark.circle.fill" : "crop")
                        .font(.caption.bold())
                        .foregroundStyle(isCropMode ? .white : .blue)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(isCropMode ? Color.blue : Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            GeometryReader { geo in
                let displayImage = showFullPage ? screenshot.image : screenshot.displayImage
                Image(uiImage: displayImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .overlay {
                        if isCropMode {
                            cropOverlay(in: geo.size)
                        }
                    }
                    .gesture(isCropMode ? cropGesture(in: geo.size) : nil)
            }
            .aspectRatio(CGFloat(screenshot.image.size.width) / CGFloat(screenshot.image.size.height), contentMode: .fit)

            if isCropMode {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw.fill").font(.caption).foregroundStyle(.blue)
                    Text("Drag to select the region where the green banner appears")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.blue.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))

                if cropStart != .zero && cropEnd != .zero {
                    HStack(spacing: 8) {
                        Button {
                            applyCrop()
                        } label: {
                            Label("Save Crop Region", systemImage: "crop")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.blue).foregroundStyle(.white).clipShape(.rect(cornerRadius: 10))
                        }
                        Button {
                            scanCropForBanner()
                        } label: {
                            Label("Scan Region", systemImage: "viewfinder")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.green.opacity(0.15)).foregroundStyle(.green).clipShape(.rect(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    private func cropOverlay(in size: CGSize) -> some View {
        ZStack {
            if cropStart != .zero && cropEnd != .zero {
                let rect = normalizedCropRect(in: size)
                Rectangle()
                    .fill(.black.opacity(0.3))
                    .reverseMask {
                        Rectangle()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                    }

                Rectangle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func cropGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let start = CGPoint(
                    x: max(0, min(value.startLocation.x, size.width)),
                    y: max(0, min(value.startLocation.y, size.height))
                )
                let end = CGPoint(
                    x: max(0, min(value.location.x, size.width)),
                    y: max(0, min(value.location.y, size.height))
                )
                cropStart = start
                cropEnd = end
                isDragging = true
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    private func normalizedCropRect(in size: CGSize) -> CGRect {
        let x = min(cropStart.x, cropEnd.x)
        let y = min(cropStart.y, cropEnd.y)
        let w = abs(cropEnd.x - cropStart.x)
        let h = abs(cropEnd.y - cropStart.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func applyCrop() {
        guard cropStart != .zero, cropEnd != .zero else { return }
        let imageSize = screenshot.image.size
        let displayAspect = imageSize.width / imageSize.height

        let viewWidth = UIScreen.main.bounds.width - 32
        let viewHeight = viewWidth / displayAspect
        let viewSize = CGSize(width: viewWidth, height: viewHeight)

        let rect = normalizedCropRect(in: viewSize)

        let scaleX = imageSize.width / viewSize.width
        let scaleY = imageSize.height / viewSize.height

        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        if let cgImage = screenshot.image.cgImage,
           let cropped = cgImage.cropping(to: pixelRect) {
            screenshot.croppedImage = UIImage(cgImage: cropped, scale: screenshot.image.scale, orientation: screenshot.image.imageOrientation)
            withAnimation(.snappy) {
                isCropMode = false
                showFullPage = false
            }
        }
    }

    private func scanCropForBanner() {
        guard cropStart != .zero, cropEnd != .zero else { return }
        let imageSize = screenshot.image.size
        let displayAspect = imageSize.width / imageSize.height

        let viewWidth = UIScreen.main.bounds.width - 32
        let viewHeight = viewWidth / displayAspect
        let viewSize = CGSize(width: viewWidth, height: viewHeight)

        let rect = normalizedCropRect(in: viewSize)

        let normalizedRect = CGRect(
            x: rect.origin.x / viewSize.width,
            y: rect.origin.y / viewSize.height,
            width: rect.width / viewSize.width,
            height: rect.height / viewSize.height
        )

        let result = GreenBannerDetector.detectInCropRegion(image: screenshot.image, cropRect: normalizedRect)
        withAnimation(.snappy) {
            if result.detected {
                bannerScanResult = "GREEN BANNER DETECTED (confidence: \(String(format: "%.0f%%", result.confidence * 100)))"
            } else {
                bannerScanResult = "No green banner found in selected region"
            }
        }
    }

    private var greenBannerScanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "viewfinder.rectangular").foregroundStyle(.green)
                Text("Green Banner Detection").font(.headline)
                Spacer()
                Button {
                    let result = GreenBannerDetector.detect(in: screenshot.image)
                    withAnimation(.snappy) {
                        if result.detected {
                            bannerScanResult = "GREEN BANNER DETECTED (confidence: \(String(format: "%.0f%%", result.confidence * 100)), rows: \(String(format: "%.1f%%", result.greenRowPercentage)))"
                        } else {
                            bannerScanResult = "No green banner found in full screenshot"
                        }
                    }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.green.opacity(0.12)).foregroundStyle(.green).clipShape(Capsule())
                }
            }

            if let scanResult = bannerScanResult {
                HStack(spacing: 6) {
                    Image(systemName: scanResult.contains("DETECTED") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(scanResult.contains("DETECTED") ? .green : .red)
                    Text(scanResult)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(scanResult.contains("DETECTED") ? .green : .red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((scanResult.contains("DETECTED") ? Color.green : Color.red).opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
            }

            Text("Only a green \"Welcome\" banner confirms a successful login. Use Crop Region to mark the detection area.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var autoDetectionInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu").foregroundStyle(.blue)
                Text("Auto Detection").font(.headline)
                Spacer()
                autoDetectionBadge
            }

            if !screenshot.note.isEmpty {
                Text(screenshot.note)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var autoDetectionBadge: some View {
        Group {
            switch screenshot.autoDetectedResult {
            case .pass:
                Label("PASS", systemImage: "checkmark.circle.fill")
                    .font(.caption.bold()).foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.green.opacity(0.12)).clipShape(Capsule())
            case .fail:
                Label("FAIL", systemImage: "xmark.circle.fill")
                    .font(.caption.bold()).foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.12)).clipShape(Capsule())
            case .unknown:
                Label("UNCERTAIN", systemImage: "questionmark.circle.fill")
                    .font(.caption.bold()).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12)).clipShape(Capsule())
            }
        }
    }

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange); Text("Correct Result").font(.headline) }

            if screenshot.hasUserOverride {
                HStack(spacing: 8) {
                    Image(systemName: screenshot.userOverride == .markedPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(screenshot.userOverride == .markedPass ? .green : .red)
                    Text("You marked this as: \(screenshot.overrideLabel)").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Reset") { vm.resetScreenshotOverride(screenshot) }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(12).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button { pendingOverride = .markedPass; showConfirmCorrection = true } label: {
                    Label("Pass", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(screenshot.userOverride == .markedPass ? Color.green : Color.green.opacity(0.15))
                        .foregroundStyle(screenshot.userOverride == .markedPass ? .white : .green)
                        .clipShape(.rect(cornerRadius: 10))
                }
                Button { pendingOverride = .markedFail; showConfirmCorrection = true } label: {
                    Label("Fail", systemImage: "xmark.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(screenshot.userOverride == .markedFail ? Color.red : Color.red.opacity(0.15))
                        .foregroundStyle(screenshot.userOverride == .markedFail ? .white : .red)
                        .clipShape(.rect(cornerRadius: 10))
                }
                Button { showRetestConfirmation = true } label: {
                    Label("Retest", systemImage: "arrow.clockwise.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange).clipShape(.rect(cornerRadius: 10))
                }
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "pencil.line").foregroundStyle(.orange); Text("Your Note").font(.headline) }

            TextField("Add a note...", text: $editingNote, axis: .vertical)
                .textFieldStyle(.plain).font(.system(.subheadline, design: .monospaced)).lineLimit(3...6)
                .padding(12).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))

            if editingNote != screenshot.userNote {
                Button {
                    screenshot.userNote = editingNote
                } label: {
                    Text("Save Note").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.accentColor).foregroundStyle(.white).clipShape(.rect(cornerRadius: 10))
                }
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }
}

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
        )
    }
}

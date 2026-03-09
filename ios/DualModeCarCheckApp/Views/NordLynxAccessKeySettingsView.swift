import SwiftUI

struct NordLynxAccessKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKeyID: String = NordLynxConfigGeneratorService.selectedKeyID
    @State private var customKeyInput: String = ""
    @State private var customNameInput: String = ""
    @State private var showAddCustom: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var saved: Bool = false
    @State private var keyChangeBounce: Int = 0

    private let tintColor = Color(red: 0.0, green: 0.78, blue: 1.0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    activeKeyCard
                    keySelectionSection
                    if !showAddCustom {
                        addCustomKeyButton
                    }
                    if showAddCustom {
                        customKeyInputSection
                    }
                    infoSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        .black, Color(red: 0.03, green: 0.05, blue: 0.15), .black,
                        Color(red: 0.0, green: 0.08, blue: 0.12), Color(red: 0.02, green: 0.06, blue: 0.18), Color(red: 0.0, green: 0.04, blue: 0.1),
                        .black, Color(red: 0.0, green: 0.06, blue: 0.1), .black
                    ]
                )
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
            .navigationTitle("Access Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .alert("Remove Custom Key?", isPresented: $showDeleteConfirmation) {
                Button("Remove", role: .destructive) {
                    removeCustomKey()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your custom access key.")
            }
        }
    }

    private var activeKeyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: keyChangeBounce)

            let activeKey = NordLynxConfigGeneratorService.activeAccessKey
            Text("Active: \(activeKey.name)")
                .font(.headline)
                .foregroundStyle(.white)

            Text(maskedKey(activeKey.key))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if saved {
                Label("Key switched successfully", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .animation(.spring(response: 0.4), value: saved)
    }

    private var keySelectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Select Access Key", systemImage: "key.horizontal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(NordLynxConfigGeneratorService.allAvailableKeys) { key in
                    keyRow(key)
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private func keyRow(_ key: NordLynxAccessKey) -> some View {
        let isSelected = selectedKeyID == key.id
        return Button {
            guard !isSelected else { return }
            withAnimation(.snappy(duration: 0.25)) {
                selectedKeyID = key.id
                NordLynxConfigGeneratorService.selectKey(key.id)
                keyChangeBounce += 1
            }
            showSavedFeedback()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? tintColor : Color.white.opacity(0.08))
                        .frame(width: 36, height: 36)

                    if key.isPreset {
                        Text(String(key.name.prefix(1)).uppercased())
                            .font(.system(.subheadline, design: .default, weight: .bold))
                            .foregroundStyle(isSelected ? .black : .secondary)
                    } else {
                        Image(systemName: "key")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? .black : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(key.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        if key.isPreset {
                            Text("PRESET")
                                .font(.system(.caption2, design: .default, weight: .bold))
                                .foregroundStyle(tintColor.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tintColor.opacity(0.15), in: .capsule)
                        } else {
                            Text("CUSTOM")
                                .font(.system(.caption2, design: .default, weight: .bold))
                                .foregroundStyle(.orange.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: .capsule)
                        }
                    }

                    Text(maskedKey(key.key))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(tintColor)
                        .transition(.scale.combined(with: .opacity))
                }

                if !key.isPreset {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.7))
                            .padding(6)
                            .background(.red.opacity(0.1), in: .circle)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected ? tintColor.opacity(0.08) : Color.white.opacity(0.03),
                in: .rect(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? tintColor.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .sensoryFeedback(.selection, trigger: selectedKeyID)
    }

    private var addCustomKeyButton: some View {
        Button {
            withAnimation(.spring(response: 0.4)) {
                showAddCustom = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tintColor)
                Text("Add Custom Key")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
    }

    private var customKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Add Custom Key", systemImage: "key.viewfinder")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showAddCustom = false
                        customKeyInput = ""
                        customNameInput = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Key Name (e.g. Work, Personal)", text: $customNameInput)
                .font(.subheadline)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))

            TextField("Paste your NordVPN access key…", text: $customKeyInput, axis: .vertical)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(3)
                .padding(12)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))

            Button {
                saveCustomKey()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Save & Activate")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(tintColor)
            .disabled(customKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How to get your access key", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(number: "1", text: "Log in to your NordVPN account dashboard")
                infoRow(number: "2", text: "Go to NordVPN → Manual Setup")
                infoRow(number: "3", text: "Copy your Access Token / Private Key")
                infoRow(number: "4", text: "Add it as a custom key above")
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private func infoRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(tintColor)
                .frame(width: 20, height: 20)
                .background(tintColor.opacity(0.15), in: .circle)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        let prefix = key.prefix(6)
        let suffix = key.suffix(6)
        return "\(prefix)••••••••\(suffix)"
    }

    private func saveCustomKey() {
        let name = customNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        NordLynxConfigGeneratorService.saveCustomKey(name: name.isEmpty ? "Custom" : name, key: customKeyInput)
        selectedKeyID = "custom"
        keyChangeBounce += 1
        showSavedFeedback()
        withAnimation(.spring(response: 0.3)) {
            showAddCustom = false
            customKeyInput = ""
            customNameInput = ""
        }
    }

    private func removeCustomKey() {
        NordLynxConfigGeneratorService.removeCustomKey()
        withAnimation(.snappy(duration: 0.25)) {
            selectedKeyID = NordLynxConfigGeneratorService.selectedKeyID
        }
        keyChangeBounce += 1
        showSavedFeedback()
    }

    private func showSavedFeedback() {
        withAnimation(.spring(response: 0.4)) {
            saved = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                saved = false
            }
        }
    }
}

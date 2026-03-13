import SwiftUI

struct TestDebugSetupView: View {
    @Bindable var vm: TestDebugViewModel
    @State private var emailInputs: [String] = [""]
    @State private var passwordInputs: [String] = [""]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                credentialSection
                sitePickerSection
                sessionCountSection
                variationModeSection
                startButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Test & Debug")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            syncInputsFromVM()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "flask.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: .purple.opacity(0.4), radius: 12)

            Text("Known Account Optimizer")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Enter a known working credential and run multiple sessions with varying settings to find the optimal configuration.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.bottom, 4)
    }

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Credentials", systemImage: "person.badge.key.fill")
                    .font(.headline)
                Spacer()
                if emailInputs.count < 3 {
                    Button {
                        emailInputs.append("")
                        passwordInputs.append("")
                        vm.addCredentialSlot()
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            ForEach(0..<emailInputs.count, id: \.self) { index in
                credentialCard(index: index)
            }
        }
    }

    private func credentialCard(index: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Account \(index + 1)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if emailInputs.count > 1 {
                    Button {
                        emailInputs.remove(at: index)
                        passwordInputs.remove(at: index)
                        vm.removeCredentialSlot(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }

            TextField("Email", text: Binding(
                get: { index < emailInputs.count ? emailInputs[index] : "" },
                set: { newVal in
                    guard index < emailInputs.count else { return }
                    emailInputs[index] = newVal
                    syncToVM(index: index)
                }
            ))
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))

            SecureField("Password", text: Binding(
                get: { index < passwordInputs.count ? passwordInputs[index] : "" },
                set: { newVal in
                    guard index < passwordInputs.count else { return }
                    passwordInputs[index] = newVal
                    syncToVM(index: index)
                }
            ))
            .textContentType(.password)
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var sitePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Target Site", systemImage: "globe")
                .font(.headline)

            HStack(spacing: 0) {
                ForEach(TestDebugSite.allCases, id: \.self) { site in
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            vm.selectedSite = site
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: site.icon)
                                .font(.system(size: 14, weight: .bold))
                            Text(site.rawValue)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(vm.selectedSite == site ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            Group {
                                if vm.selectedSite == site {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(site == .joe
                                              ? LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .top, endPoint: .bottom)
                                              : LinearGradient(colors: [.orange.opacity(0.8), .orange], startPoint: .top, endPoint: .bottom))
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    private var sessionCountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Session Count", systemImage: "number.circle.fill")
                .font(.headline)

            HStack(spacing: 0) {
                ForEach(TestDebugSessionCount.allCases, id: \.self) { count in
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            vm.sessionCount = count
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(count.label)
                                .font(.system(size: 20, weight: .black, design: .monospaced))
                            Text("\(Int(ceil(Double(count.rawValue) / 6.0))) waves")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(vm.sessionCount == count ? .white.opacity(0.7) : .secondary)
                        }
                        .foregroundStyle(vm.sessionCount == count ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(
                            Group {
                                if vm.sessionCount == count {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(LinearGradient(colors: [.purple.opacity(0.8), .purple], startPoint: .top, endPoint: .bottom))
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    private var variationModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Variation Focus", systemImage: "slider.horizontal.3")
                .font(.headline)

            VStack(spacing: 6) {
                ForEach(TestDebugVariationMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            vm.variationMode = mode
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 32)
                                .foregroundStyle(vm.variationMode == mode ? .white : .purple)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                Text(mode.subtitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(vm.variationMode == mode ? .white.opacity(0.7) : .secondary)
                            }

                            Spacer()

                            if vm.variationMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white)
                            }
                        }
                        .foregroundStyle(vm.variationMode == mode ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            Group {
                                if vm.variationMode == mode {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(.tertiarySystemGroupedBackground))
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    private var startButton: some View {
        Button {
            vm.startTest()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("START TEST")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                Group {
                    if vm.canStart {
                        LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color.gray.opacity(0.4)
                    }
                }
            )
            .clipShape(.rect(cornerRadius: 16))
            .shadow(color: vm.canStart ? .purple.opacity(0.4) : .clear, radius: 12, y: 4)
        }
        .disabled(!vm.canStart)
        .sensoryFeedback(.impact(weight: .heavy), trigger: vm.phase == .running)
        .padding(.top, 8)
    }

    private func syncInputsFromVM() {
        emailInputs = vm.credentials.map(\.email)
        passwordInputs = vm.credentials.map(\.password)
    }

    private func syncToVM(index: Int) {
        guard index < emailInputs.count, index < passwordInputs.count else { return }
        vm.updateCredential(at: index, email: emailInputs[index], password: passwordInputs[index])
    }
}

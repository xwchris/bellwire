import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isGeneratingBinding = false
    @State private var showsAgentInstructions = false
    @State private var showsSignOutConfirmation = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BellwireSpacing.section) {
                    Text("Settings")
                        .font(BellwireTypography.pageTitle)
                        .foregroundStyle(BellwireTheme.ink)
                        .accessibilityAddTraits(.isHeader)

                    accountCard
                    connectionSection
                    notificationsSection
                    appPreferencesSection
                    devicesSection
                    accountSection

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { model.errorMessage = nil }
                    }

                    Text(appVersion)
                        .bellwireTechnicalLabel()
                        .frame(maxWidth: .infinity)
                        .padding(.top, BellwireSpacing.compact)
                }
                .padding(.horizontal, BellwireSpacing.roomy)
                .padding(.top, BellwireSpacing.standard)
                .padding(.bottom, BellwireSpacing.large)
            }
            .bellwirePageBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await model.refreshNotificationStatus()
                await model.loadDashboard()
            }
            .sheet(item: $model.binding) { binding in
                BindingCodeSheet(binding: binding)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsAgentInstructions) {
                AgentInstructionSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Sign out of Bellwire?",
                isPresented: $showsSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { model.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local session will be removed. Connected projects and server data are not deleted.")
            }
        }
    }

    private var accountCard: some View {
        HStack(spacing: BellwireSpacing.standard) {
            Text(accountInitial)
                .font(.system(.title2, design: .serif, weight: .regular))
                .foregroundStyle(BellwireTheme.accentInk)
                .frame(width: 50, height: 50)
                .background(
                    LinearGradient(
                        colors: [BellwireTheme.accent, BellwireTheme.warning],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(accountName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BellwireTheme.ink)
                    .lineLimit(1)
                Text("Signed in with Apple")
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.mutedInk)
            }
            Spacer()
            StatusBadgeView(text: "Connected", color: BellwireTheme.success)
        }
        .padding(BellwireSpacing.standard)
        .bellwireSurface()
        .accessibilityElement(children: .combine)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "Agent connection")
            VStack(spacing: 0) {
                Button {
                    isGeneratingBinding = true
                    Task {
                        await model.createBinding()
                        isGeneratingBinding = false
                    }
                } label: {
                    SettingsRowView(
                        icon: BellwireIcons.binding,
                        title: isGeneratingBinding ? "Generating binding code…" : "Generate binding code",
                        hint: "Single-use · expires after 10 minutes"
                    ) {
                        if isGeneratingBinding {
                            ProgressView().tint(BellwireTheme.accent)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BellwireTheme.mutedInk)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isGeneratingBinding)
                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                Button { showsAgentInstructions = true } label: {
                    SettingsRowView(
                        icon: "text.bubble",
                        title: "How to instruct your Agent",
                        hint: "Codex, Claude Code, or another Agent"
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.mutedInk)
                    }
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, BellwireSpacing.standard)
            .bellwireSurface()
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "Notifications")
            VStack(spacing: 0) {
                SettingsRowView(
                    icon: BellwireIcons.notification,
                    title: "Notification permission",
                    hint: notificationHint
                ) {
                    StatusBadgeView(
                        text: model.notificationPermission.label,
                        color: notificationColor,
                        showsDot: model.notificationPermission == .authorized
                    )
                }
                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                Button { openSystemSettings() } label: {
                    SettingsRowView(
                        icon: "gearshape",
                        title: "Open iOS Settings",
                        hint: "Manage alerts, sounds, and badges"
                    ) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.mutedInk)
                    }
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, BellwireSpacing.standard)
            .bellwireSurface()
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "Devices", hint: model.devices.isEmpty ? nil : "\(model.devices.count)")
            if model.devices.isEmpty {
                EmptyState(
                    icon: BellwireIcons.device,
                    title: "No registered devices",
                    message: "This iPhone appears after notification permission and APNs registration succeed."
                )
                .bellwireSurface(elevated: false)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        DeviceRowView(device: device)
                        if index < model.devices.count - 1 {
                            Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                        }
                    }
                }
                .padding(.horizontal, BellwireSpacing.standard)
                .bellwireSurface()
            }
        }
    }

    private var appPreferencesSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "App")
            Menu {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        appLanguage = language.rawValue
                        BellwireHaptics.selection()
                    } label: {
                        if selectedLanguage == language {
                            Label {
                                Text(language.title)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(language.title)
                        }
                    }
                }
            } label: {
                SettingsRowView(
                    icon: "globe",
                    title: "Language",
                    hint: "Choose the language used throughout Bellwire"
                ) {
                    HStack(spacing: 5) {
                        Text(selectedLanguage.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.accent)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(BellwireTheme.mutedInk)
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Language")
            .accessibilityValue(Text(selectedLanguage.title))
            .accessibilityHint("Changes the language used throughout Bellwire")
            .padding(.horizontal, BellwireSpacing.standard)
            .bellwireSurface()
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "Account")
            VStack(spacing: 0) {
                SettingsRowView(
                    icon: "hand.raised",
                    title: "Privacy policy",
                    hint: "Policy link is not configured in this build"
                ) {
                    Image(systemName: "minus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BellwireTheme.mutedInk)
                }
                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                Button { showsSignOutConfirmation = true } label: {
                    SettingsRowView(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Sign out",
                        tone: BellwireTheme.danger
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.danger)
                    }
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, BellwireSpacing.standard)
            .bellwireSurface()
        }
    }

    private var accountName: String {
        model.session?.user.email ?? "Apple account"
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage.selected(from: appLanguage)
    }

    private var accountInitial: String {
        String(accountName.first ?? "B").uppercased()
    }

    private var notificationHint: String {
        switch model.notificationPermission {
        case .unknown: return "Checking the system permission"
        case .notDetermined: return "Permission has not been requested"
        case .denied: return "Enable notifications in iOS Settings"
        case .authorized: return "Alerts can be delivered to this device"
        }
    }

    private var notificationColor: Color {
        switch model.notificationPermission {
        case .authorized: return BellwireTheme.success
        case .denied: return BellwireTheme.danger
        case .unknown, .notDetermined: return BellwireTheme.mutedInk
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Bellwire \(version) · build \(build)"
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct BindingCodeSheet: View {
    @Environment(\.locale) private var locale
    let binding: BindingResponse
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAction: CopiedBindingAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BellwireSpacing.section) {
                HStack {
                    BellwireMark(size: 42)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BellwireTheme.accent)
                        .frame(minHeight: 44)
                        .buttonStyle(PressableButtonStyle())
                }

                VStack(alignment: .leading, spacing: BellwireSpacing.small) {
                    Text("Binding code")
                        .bellwireTechnicalLabel()
                    Text("Hand this to\nyour Agent.")
                        .font(BellwireTypography.pageTitle)
                        .foregroundStyle(BellwireTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("This code is single-use. Once your Agent connects, project events can start flowing into Bellwire.")
                        .font(.subheadline)
                        .foregroundStyle(BellwireTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                codeCard
                instructionCard

                VStack(spacing: BellwireSpacing.small) {
                    PrimaryButton(
                        title: copiedAction == .instruction ? "Instruction copied" : "Copy instruction",
                        systemImage: copiedAction == .instruction ? "checkmark" : BellwireIcons.copy
                    ) {
                        UIPasteboard.general.string = instruction
                        copiedAction = .instruction
                        BellwireHaptics.success()
                    }
                    SecondaryButton(
                        title: copiedAction == .code ? "Code copied" : "Copy code only",
                        systemImage: copiedAction == .code ? "checkmark" : BellwireIcons.copy
                    ) {
                        UIPasteboard.general.string = binding.code
                        copiedAction = .code
                        BellwireHaptics.success()
                    }
                }
            }
            .padding(BellwireSpacing.page)
        }
        .bellwirePageBackground()
    }

    private var codeCard: some View {
        VStack(spacing: BellwireSpacing.standard) {
            HStack {
                Text("Expires")
                    .bellwireTechnicalLabel()
                Spacer()
                if let expiryDate {
                    Text(BellwireDateFormatting.relative(expiryDate, locale: locale))
                        .font(BellwireTypography.technicalStrong)
                        .monospacedDigit()
                        .foregroundStyle(BellwireTheme.accent)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { codeDigits }
                Text(binding.code.chunkedPairs)
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .tracking(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(BellwireTheme.ink)
        .padding(BellwireSpacing.standard)
        .background {
            RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
                .fill(BellwireTheme.surface)
                .overlay(BellwireTheme.amberGlow.clipShape(RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
                .stroke(BellwireTheme.strongSeparator, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Binding code \(binding.code)")
    }

    private var codeDigits: some View {
        ForEach(Array(binding.code.enumerated()), id: \.offset) { _, digit in
            Text(String(digit))
                .font(.system(.title2, design: .serif, weight: .semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(BellwireTheme.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(BellwireTheme.strongSeparator, lineWidth: 1)
                }
        }
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            Text("Say this to your Agent")
                .bellwireTechnicalLabel()
            Text("> ")
                .foregroundStyle(BellwireTheme.mutedInk)
            + Text("Connect Bellwire with code ")
                .foregroundStyle(BellwireTheme.ink)
            + Text(binding.code)
                .foregroundStyle(BellwireTheme.accent)
            + Text(".")
                .foregroundStyle(BellwireTheme.ink)
        }
        .font(.system(.body, design: .monospaced))
        .padding(BellwireSpacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bellwireSurface(radius: BellwireRadius.card, elevated: false)
        .textSelection(.enabled)
    }

    private var instruction: String {
        "Connect Bellwire with code \(binding.code)."
    }

    private var expiryDate: Date? {
        ISO8601DateFormatter.bellwireDate(from: binding.expiresAt)
    }
}

private enum CopiedBindingAction {
    case instruction
    case code
}

private struct AgentInstructionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.roomy) {
            HStack {
                Text("Instruct your Agent")
                    .font(.system(.title2, design: .serif, weight: .regular))
                    .foregroundStyle(BellwireTheme.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .foregroundStyle(BellwireTheme.accent)
                    .frame(minHeight: 44)
            }
            Text("1. Generate a binding code.\n2. Open the project with your Agent.\n3. Say: “Connect Bellwire with code …”\n4. Let the Agent configure the supported event and live-surface calls.")
                .font(.body)
                .foregroundStyle(BellwireTheme.secondaryInk)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(BellwireSpacing.page)
        .bellwirePageBackground()
    }
}

private extension String {
    var chunkedPairs: String {
        stride(from: 0, to: count, by: 2).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(2, count - offset))
            return String(self[start..<end])
        }.joined(separator: " ")
    }
}

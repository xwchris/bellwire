// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit
import MessageUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var isGeneratingBinding = false
    @State private var showsAgentInstructions = false
    @State private var showsSignOutConfirmation = false
    @State private var showsDeleteAccountPage = false
    @State private var showsFeedbackMail = false
    @State private var showsFeedbackFallback = false
    @State private var feedbackEmailCopied = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearance = AppAppearance.system.rawValue

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
                    supportSection
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
            .sheet(isPresented: $showsFeedbackMail) {
                FeedbackMailView(
                    isPresented: $showsFeedbackMail,
                    recipient: feedbackEmail,
                    subject: "Bellwire Feedback",
                    body: feedbackBody
                )
            }
            .alert("Feedback unavailable", isPresented: $showsFeedbackFallback) {
                Button("Copy email") {
                    UIPasteboard.general.string = feedbackEmail
                    feedbackEmailCopied = true
                    BellwireHaptics.success()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("No mail account is configured. Copy the feedback email instead?")
            }
            .alert(
                "Sign out of Bellwire?",
                isPresented: $showsSignOutConfirmation
            ) {
                Button("Sign out", role: .destructive) { model.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local session will be removed. Connected projects and server data are not deleted.")
            }
            .navigationDestination(isPresented: $showsDeleteAccountPage) {
                DeleteAccountView()
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
            VStack(spacing: 0) {
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
                        settingSelectionLabel(selectedLanguage.title)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Language")
                .accessibilityValue(Text(selectedLanguage.title))
                .accessibilityHint("Changes the language used throughout Bellwire")

                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)

                Menu {
                    ForEach(AppAppearance.allCases) { appearance in
                        Button {
                            withAnimation(reduceMotion ? nil : BellwireAnimation.standard) {
                                appAppearance = appearance.rawValue
                            }
                            BellwireHaptics.selection()
                        } label: {
                            if selectedAppearance == appearance {
                                Label {
                                    Text(appearance.title)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(appearance.title)
                            }
                        }
                    }
                } label: {
                    SettingsRowView(
                        icon: "circle.lefthalf.filled",
                        title: "Appearance",
                        hint: "Choose the appearance used throughout Bellwire"
                    ) {
                        settingSelectionLabel(selectedAppearance.title)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Appearance")
                .accessibilityValue(Text(selectedAppearance.title))
                .accessibilityHint("Changes Bellwire between light and dark appearance")
            }
            .padding(.horizontal, BellwireSpacing.standard)
            .bellwireSurface()
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "Support")
            VStack(spacing: 0) {
                Button { openSupport() } label: {
                    SettingsRowView(
                        icon: "questionmark.circle",
                        title: "Help and support",
                        hint: "Setup help and troubleshooting"
                    ) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.mutedInk)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("Opens Bellwire support in your browser")
                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                Button { openFeedback() } label: {
                    SettingsRowView(
                        icon: feedbackEmailCopied ? "checkmark" : "bubble.left.and.bubble.right",
                        title: "Send feedback",
                        hint: feedbackEmailCopied ? "Feedback email copied" : "Help improve Bellwire"
                    ) {
                        Image(systemName: feedbackEmailCopied ? "checkmark" : "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(feedbackEmailCopied ? BellwireTheme.success : BellwireTheme.mutedInk)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("Opens an email to Bellwire support")
            }
            .padding(.horizontal, BellwireSpacing.standard)
            .bellwireSurface()
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.small) {
            SectionHeaderView(title: "Account")
            VStack(spacing: 0) {
                Button { openPrivacyPolicy() } label: {
                    SettingsRowView(
                        icon: "hand.raised",
                        title: "Privacy policy",
                        hint: "How Bellwire handles account, device, and project data"
                    ) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.mutedInk)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("Opens the Bellwire privacy policy in your browser")
                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                Button { openTermsOfService() } label: {
                    SettingsRowView(
                        icon: "doc.text",
                        title: "Terms of service",
                        hint: "Rules for using Bellwire"
                    ) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BellwireTheme.mutedInk)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("Opens the Bellwire terms of service in your browser")
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
                Divider().overlay(BellwireTheme.separator).padding(.leading, 44)
                Button { showsDeleteAccountPage = true } label: {
                    SettingsRowView(
                        icon: "person.crop.circle.badge.minus",
                        title: "Delete account",
                        hint: "Permanently delete your account and data",
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

    private var selectedAppearance: AppAppearance {
        AppAppearance.selected(from: appAppearance)
    }

    private func settingSelectionLabel(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BellwireTheme.accent)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BellwireTheme.mutedInk)
        }
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

    private var feedbackEmail: String { "feedback@bellwire.app" }

    private var feedbackBody: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let device = UIDevice.current
        return """
        请在这里填写反馈 / Please write your feedback here.


        ---
        Bellwire \(version) (\(build))
        \(device.localizedModel) · \(device.systemName) \(device.systemVersion)
        """
    }

    private func openFeedback() {
        feedbackEmailCopied = false
        if MFMailComposeViewController.canSendMail() {
            showsFeedbackMail = true
        } else {
            showsFeedbackFallback = true
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openPrivacyPolicy() {
        guard let url = URL(string: "https://bellwire.app/privacy") else { return }
        openURL(url)
    }

    private func openTermsOfService() {
        guard let url = URL(string: "https://bellwire.app/terms") else { return }
        openURL(url)
    }

    private func openSupport() {
        guard let url = URL(string: "https://bellwire.app/support") else { return }
        openURL(url)
    }
}

private struct DeleteAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsFinalConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deletionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BellwireSpacing.section) {
                VStack(alignment: .leading, spacing: BellwireSpacing.standard) {
                    Image(systemName: "person.crop.circle.badge.minus")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(BellwireTheme.danger)
                        .frame(width: 58, height: 58)
                        .background(BellwireTheme.danger.opacity(0.12), in: Circle())

                    Text("Delete your account?")
                        .font(BellwireTypography.pageTitle)
                        .foregroundStyle(BellwireTheme.ink)
                        .accessibilityAddTraits(.isHeader)

                    Text("Your Bellwire account and all connected data will be permanently deleted.")
                        .font(.body)
                        .foregroundStyle(BellwireTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: BellwireSpacing.standard) {
                    Text("This will delete")
                        .bellwireTechnicalLabel()
                    deletionItem(icon: "square.stack.3d.up", title: "Projects and live cards")
                    deletionItem(icon: "tray.full", title: "Events and notification history")
                    deletionItem(icon: "iphone", title: "Registered devices")
                    deletionItem(icon: "link", title: "Agent connections and access tokens")
                }
                .padding(BellwireSpacing.standard)
                .bellwireSurface(elevated: false)

                HStack(alignment: .top, spacing: BellwireSpacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BellwireTheme.danger)
                    Text("This action cannot be undone. You will need to create a new account to use Bellwire again.")
                        .font(.subheadline)
                        .foregroundStyle(BellwireTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let deletionError {
                    ErrorBanner(message: deletionError) {
                        self.deletionError = nil
                    }
                }

                Button {
                    showsFinalConfirmation = true
                } label: {
                    HStack(spacing: BellwireSpacing.compact) {
                        if isDeletingAccount {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(isDeletingAccount ? "Deleting account…" : "Permanently delete account")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .background(BellwireTheme.danger, in: RoundedRectangle(cornerRadius: BellwireRadius.control, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isDeletingAccount)
            }
            .padding(.horizontal, BellwireSpacing.roomy)
            .padding(.top, BellwireSpacing.standard)
            .padding(.bottom, BellwireSpacing.large)
        }
        .bellwirePageBackground()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .interactiveDismissDisabled(isDeletingAccount)
        .alert(
            "Permanently delete your Bellwire account?",
            isPresented: $showsFinalConfirmation
        ) {
            Button("Delete account and data", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all Bellwire data. This action cannot be undone.")
        }
    }

    private func deletionItem(icon: String, title: String) -> some View {
        HStack(spacing: BellwireSpacing.small) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(BellwireTheme.danger)
                .frame(width: 28, height: 28)
                .background(BellwireTheme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: BellwireRadius.small, style: .continuous))
            Text(LocalizedStringKey(title))
                .font(.subheadline)
                .foregroundStyle(BellwireTheme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func deleteAccount() {
        guard !isDeletingAccount else { return }
        deletionError = nil
        isDeletingAccount = true
        Task {
            let deleted = await model.deleteAccount()
            isDeletingAccount = false
            if deleted {
                dismiss()
            } else {
                deletionError = model.errorMessage ?? String(localized: "Unable to delete account. Please try again.")
            }
        }
    }
}

private struct FeedbackMailView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let recipient: String
    let subject: String
    let body: String

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding private var isPresented: Bool

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            isPresented = false
        }
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

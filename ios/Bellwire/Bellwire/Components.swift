// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit

enum BellwireIcons {
    static let home = "house"
    static let projects = "square.grid.2x2"
    static let events = "bolt"
    static let settings = "gearshape"
    static let notification = "bell.fill"
    static let binding = "key.horizontal"
    static let device = "iphone"
    static let copy = "doc.on.doc"
}

struct BellwireMark: View {
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(BellwireTheme.brandOrange)
            Image(systemName: BellwireIcons.notification)
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: -0.5)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

struct ProjectAvatarView: View {
    let name: String
    let icon: String
    var size: CGFloat = 44
    var logoURL: URL? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(avatarGradient)
            Text(initials)
                .font(.system(size: size * 0.34, weight: .semibold, design: .default))
                .tracking(-0.35)
                .minimumScaleFactor(0.7)
            if let logoURL {
                AsyncImage(url: logoURL, transaction: Transaction(animation: BellwireAnimation.quick)) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .background(BellwireTheme.surface)
                            .transition(.opacity)
                    }
                }
                .frame(width: size, height: size)
                .clipped()
            }
        }
        .foregroundStyle(BellwireTheme.accentInk)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let normalized = name.lowercased()
        if normalized.contains("videosays") { return "VS" }
        if normalized.contains("bellwire") { return "BW" }
        let words = name.split(separator: " ").prefix(2)
        if words.count == 1 {
            let capitals = name.filter(\.isUppercase)
            if capitals.count >= 2 { return String(capitals.prefix(2)) }
        }
        let value = words.compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "BW" : value
    }

    private var avatarGradient: LinearGradient {
        let colors = avatarColors
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var avatarColors: [Color] {
        let normalized = name.lowercased()
        if normalized.contains("videosays") {
            return [Color(red: 0.96, green: 0.67, blue: 0.16), Color(red: 0.76, green: 0.43, blue: 0.05)]
        }
        if normalized.contains("content") || normalized.contains("growth") {
            return [Color(red: 0.48, green: 0.79, blue: 0.43), Color(red: 0.25, green: 0.60, blue: 0.31)]
        }
        if normalized.contains("bellwire") {
            return [Color(red: 0.42, green: 0.72, blue: 0.88), Color(red: 0.22, green: 0.51, blue: 0.72)]
        }
        if normalized.contains("production") {
            return [Color(red: 0.71, green: 0.61, blue: 0.88), Color(red: 0.48, green: 0.36, blue: 0.70)]
        }
        if normalized.contains("reddit") {
            return [Color(red: 0.83, green: 0.48, blue: 0.38), Color(red: 0.62, green: 0.29, blue: 0.23)]
        }
        let hue = Double(abs(name.hashValue % 360)) / 360
        return [
            Color(hue: hue, saturation: 0.38, brightness: 0.88),
            Color(hue: hue, saturation: 0.52, brightness: 0.66),
        ]
    }
}

struct ProjectGlyph: View {
    let icon: String
    var size: CGFloat = 44

    var body: some View {
        ProjectAvatarView(name: icon.humanizedEventType, icon: icon, size: size)
    }
}

struct SectionHeaderView: View {
    let title: String
    var hint: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .bellwireTechnicalLabel()
            Spacer()
            if let hint, !hint.isEmpty {
                Text(LocalizedStringKey(hint))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BellwireTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusBadgeView: View {
    let text: String
    let color: Color
    var showsDot = true

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.34), radius: 4)
            }
            Text(LocalizedStringKey(text))
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(minHeight: 26)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: BellwireRadius.small, style: .continuous))
        .accessibilityLabel(Text(LocalizedStringKey(text)))
    }
}

struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        StatusBadgeView(text: text, color: color)
    }
}

struct DigestMetricView: View {
    let value: Int
    let label: String
    var isAccented = false

    var body: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.micro) {
            Text(value.formatted())
                .font(BellwireTypography.metric)
                .monospacedDigit()
                .foregroundStyle(isAccented ? BellwireTheme.accent : BellwireTheme.ink)
                .contentTransition(.numericText())
            Text(LocalizedStringKey(label.lowercased()))
                .font(.caption2)
                .tracking(0.4)
                .foregroundStyle(BellwireTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BellwireSpacing.compact) {
                if isLoading {
                    ProgressView().tint(BellwireTheme.accentInk)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(LocalizedStringKey(title))
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(BellwireTheme.accentInk)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(BellwireTheme.accent, in: RoundedRectangle(cornerRadius: BellwireRadius.control, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BellwireSpacing.compact) {
                if let systemImage { Image(systemName: systemImage) }
                Text(LocalizedStringKey(title)).font(.body.weight(.semibold))
            }
            .foregroundStyle(BellwireTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(BellwireTheme.surface, in: RoundedRectangle(cornerRadius: BellwireRadius.control, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: BellwireSpacing.small) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(BellwireTheme.danger)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connection issue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BellwireTheme.ink)
                Text(LocalizedStringKey(message))
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Dismiss error")
        }
        .padding(.leading, BellwireSpacing.standard)
        .padding(.vertical, BellwireSpacing.small)
        .padding(.trailing, BellwireSpacing.micro)
        .background(BellwireTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)
                .stroke(BellwireTheme.danger.opacity(0.25), lineWidth: 1)
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: BellwireSpacing.small) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(BellwireTheme.accent)
                .frame(width: 56, height: 56)
                .background(BellwireTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            Text(LocalizedStringKey(title))
                .font(.headline)
                .foregroundStyle(BellwireTheme.ink)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(BellwireTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, BellwireSpacing.roomy)
        .padding(.vertical, 38)
        .accessibilityElement(children: .combine)
    }
}

struct LoadingEventRows: View {
    var count = 4

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: BellwireSpacing.small) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BellwireTheme.raisedSurface)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).frame(width: 138, height: 11)
                        RoundedRectangle(cornerRadius: 3).frame(maxWidth: 205).frame(height: 9)
                    }
                    .foregroundStyle(BellwireTheme.tertiarySurface)
                    Spacer()
                }
                .padding(.vertical, 13)
                if index < count - 1 {
                    Divider().overlay(BellwireTheme.separator).padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal, BellwireSpacing.standard)
        .bellwireSurface()
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

struct SettingsRowView<Accessory: View>: View {
    let icon: String
    let title: String
    var hint: String?
    var tone: Color = BellwireTheme.ink
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: BellwireSpacing.small) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tone == BellwireTheme.ink ? BellwireTheme.secondaryInk : tone)
                .frame(width: 32, height: 32)
                .background(BellwireTheme.raisedSurface, in: RoundedRectangle(cornerRadius: BellwireRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tone)
                if let hint {
                    Text(LocalizedStringKey(hint))
                        .font(.caption)
                        .foregroundStyle(BellwireTheme.mutedInk)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DeviceRowView: View {
    let device: DeviceRecord

    var body: some View {
        SettingsRowView(
            icon: BellwireIcons.device,
            title: device.name,
            hint: device.appVersion.map { "Bellwire \($0)" } ?? "Bellwire"
        ) {
            StatusBadgeView(
                text: device.pushEnabled ? "Push on" : "Push off",
                color: device.pushEnabled ? BellwireTheme.success : BellwireTheme.mutedInk,
                showsDot: false
            )
        }
    }
}

struct StructuredFieldRow: View {
    let key: String
    let value: String
    var isSensitive = false
    var isRevealed = true
    var reveal: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BellwireSpacing.standard) {
            Text(key)
                .font(BellwireTypography.technical)
                .foregroundStyle(BellwireTheme.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isSensitive && !isRevealed, let reveal {
                Button(action: reveal) {
                    Label("Hidden", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BellwireTheme.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                Text(value)
                    .font(BellwireTypography.technical)
                    .foregroundStyle(BellwireTheme.ink)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct DeliveryTimelineView: View {
    let deliveries: [DeliveryRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineRow(label: "Event received", detail: nil, color: BellwireTheme.success, isLast: deliveries.isEmpty)
            ForEach(Array(deliveries.enumerated()), id: \.element.id) { index, delivery in
                timelineRow(
                    label: deliveryLabel(delivery.status),
                    detail: "Attempt \(delivery.attemptCount)",
                    color: deliveryColor(delivery.status),
                    isLast: index == deliveries.count - 1
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func timelineRow(label: String, detail: String?, color: Color, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: BellwireSpacing.small) {
            VStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 4))
                if !isLast {
                    Rectangle().fill(BellwireTheme.strongSeparator).frame(width: 1, height: 34)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(BellwireTheme.ink)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(BellwireTypography.technical)
                        .monospacedDigit()
                        .foregroundStyle(BellwireTheme.mutedInk)
                }
            }
            .padding(.top, -4)
        }
    }

    private func deliveryLabel(_ status: String) -> String {
        switch status {
        case "accepted_by_apns": return "Accepted by APNs"
        case "failed": return "Delivery failed"
        default: return "Queued for delivery"
        }
    }

    private func deliveryColor(_ status: String) -> Color {
        switch status {
        case "accepted_by_apns": return BellwireTheme.success
        case "failed": return BellwireTheme.danger
        default: return BellwireTheme.warning
        }
    }
}

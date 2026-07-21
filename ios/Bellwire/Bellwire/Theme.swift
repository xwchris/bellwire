import SwiftUI
import UIKit

enum BellwireTheme {
    // MARK: Brand and semantic color roles

    static let accent = adaptiveColor(
        light: UIColor(red: 0.72, green: 0.43, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.68, blue: 0.24, alpha: 1)
    )
    static let accentInk = adaptiveColor(
        light: UIColor(red: 0.13, green: 0.09, blue: 0.04, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.09, blue: 0.04, alpha: 1)
    )
    static let background = adaptiveColor(
        light: UIColor(red: 0.965, green: 0.952, blue: 0.925, alpha: 1),
        dark: UIColor(red: 0.155, green: 0.148, blue: 0.138, alpha: 1)
    )
    static let surface = adaptiveColor(
        light: UIColor(red: 0.995, green: 0.985, blue: 0.962, alpha: 1),
        dark: UIColor(red: 0.205, green: 0.195, blue: 0.182, alpha: 1)
    )
    static let raisedSurface = adaptiveColor(
        light: UIColor(red: 0.935, green: 0.915, blue: 0.875, alpha: 1),
        dark: UIColor(red: 0.245, green: 0.233, blue: 0.216, alpha: 1)
    )
    static let tertiarySurface = adaptiveColor(
        light: UIColor(red: 0.89, green: 0.865, blue: 0.82, alpha: 1),
        dark: UIColor(red: 0.29, green: 0.275, blue: 0.253, alpha: 1)
    )
    static let ink = adaptiveColor(
        light: UIColor(red: 0.12, green: 0.112, blue: 0.10, alpha: 1),
        dark: UIColor(red: 0.97, green: 0.955, blue: 0.925, alpha: 1)
    )
    static let secondaryInk = adaptiveColor(
        light: UIColor(red: 0.37, green: 0.345, blue: 0.305, alpha: 1),
        dark: UIColor(red: 0.78, green: 0.745, blue: 0.69, alpha: 1)
    )
    static let mutedInk = adaptiveColor(
        light: UIColor(red: 0.49, green: 0.455, blue: 0.405, alpha: 1),
        dark: UIColor(red: 0.60, green: 0.57, blue: 0.52, alpha: 1)
    )
    static let separator = adaptiveColor(
        light: UIColor.black.withAlphaComponent(0.075),
        dark: UIColor.white.withAlphaComponent(0.09)
    )
    static let strongSeparator = adaptiveColor(
        light: UIColor.black.withAlphaComponent(0.16),
        dark: UIColor.white.withAlphaComponent(0.18)
    )
    static let live = adaptiveColor(
        light: UIColor(red: 0.15, green: 0.56, blue: 0.31, alpha: 1),
        dark: UIColor(red: 0.44, green: 0.86, blue: 0.53, alpha: 1)
    )
    static let success = adaptiveColor(
        light: UIColor(red: 0.12, green: 0.52, blue: 0.33, alpha: 1),
        dark: UIColor(red: 0.43, green: 0.83, blue: 0.58, alpha: 1)
    )
    static let warning = adaptiveColor(
        light: UIColor(red: 0.71, green: 0.43, blue: 0.05, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1)
    )
    static let danger = adaptiveColor(
        light: UIColor(red: 0.72, green: 0.20, blue: 0.16, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.39, blue: 0.32, alpha: 1)
    )

    static var amberGlow: RadialGradient {
        RadialGradient(
            colors: [accent.opacity(0.22), accent.opacity(0.06), .clear],
            center: .topTrailing,
            startRadius: 8,
            endRadius: 260
        )
    }

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum BellwireTypography {
    static let hero = Font.system(.largeTitle, design: .serif, weight: .regular)
    static let pageTitle = Font.system(.largeTitle, design: .serif, weight: .regular)
    static let sectionTitle = Font.system(.caption2, design: .monospaced, weight: .medium)
    static let technical = Font.system(.caption, design: .monospaced, weight: .regular)
    static let technicalStrong = Font.system(.caption, design: .monospaced, weight: .semibold)
    static let metric = Font.system(.title, design: .serif, weight: .regular)
}

enum BellwireSpacing {
    static let micro: CGFloat = 4
    static let compact: CGFloat = 8
    static let small: CGFloat = 12
    static let standard: CGFloat = 16
    static let roomy: CGFloat = 20
    static let section: CGFloat = 28
    static let page: CGFloat = 24
    static let large: CGFloat = 36
}

enum BellwireRadius {
    static let small: CGFloat = 8
    static let control: CGFloat = 14
    static let card: CGFloat = 18
    static let largeCard: CGFloat = 24
    static let hero: CGFloat = 32
}

enum BellwireShadow {
    static let cardColor = Color.black.opacity(0.08)
    static let cardRadius: CGFloat = 16
    static let cardY: CGFloat = 6
}

enum BellwireAnimation {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeOut(duration: 0.25)
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.88)
}

enum BellwireHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : BellwireAnimation.quick, value: configuration.isPressed)
    }
}

private struct BellwireSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                elevated ? BellwireTheme.surface : BellwireTheme.surface,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: elevated ? BellwireShadow.cardColor : .clear,
                radius: elevated ? BellwireShadow.cardRadius : 0,
                y: elevated ? BellwireShadow.cardY : 0
            )
    }
}

extension View {
    func bellwireSurface(radius: CGFloat = BellwireRadius.largeCard, elevated: Bool = true) -> some View {
        modifier(BellwireSurfaceModifier(radius: radius, elevated: elevated))
    }

    func bellwirePageBackground() -> some View {
        background(BellwireTheme.background.ignoresSafeArea())
    }

    func bellwireTechnicalLabel() -> some View {
        font(BellwireTypography.sectionTitle)
            .textCase(.uppercase)
            .tracking(1.8)
            .foregroundStyle(BellwireTheme.mutedInk)
    }
}

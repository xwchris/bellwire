import SwiftUI
import UIKit

struct LiveSurfacesSection: View {
    let surfaces: [LiveSurfaceRecord]
    var showsHeader = true
    @State private var selectedSurfaceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                SectionHeaderView(title: "Live surfaces", hint: "Updated by Agents")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(surfaces) { surface in
                        LiveSurfaceCard(surface: surface)
                            .containerRelativeFrame(.horizontal)
                            .id(surface.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 3)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selectedSurfaceID, anchor: .leading)

            if surfaces.count > 1 {
                HStack(spacing: 6) {
                    ForEach(surfaces) { surface in
                        Capsule()
                            .fill(surface.id == selectedSurfaceID
                                ? BellwireTheme.accent
                                : BellwireTheme.separator)
                            .frame(width: surface.id == selectedSurfaceID ? 16 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
        .onAppear { selectFirstSurfaceIfNeeded() }
        .onChange(of: surfaces.map(\.id)) { _, _ in selectFirstSurfaceIfNeeded() }
    }

    private func selectFirstSurfaceIfNeeded() {
        guard !surfaces.contains(where: { $0.id == selectedSurfaceID }) else { return }
        selectedSurfaceID = surfaces.first?.id
    }
}

struct LiveSurfaceCard: View {
    let surface: LiveSurfaceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            header
            content
            footer
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            surface.type == "alert" ? BellwireTheme.danger.opacity(0.075) : BellwireTheme.surface,
            in: RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
                .stroke(
                    surface.type == "alert" ? BellwireTheme.danger.opacity(0.28) : BellwireTheme.separator,
                    lineWidth: 1
                )
        }
        .shadow(color: BellwireShadow.cardColor, radius: BellwireShadow.cardRadius, y: BellwireShadow.cardY)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectAvatarView(
                name: surface.project?.name ?? surface.title,
                icon: surface.project?.icon ?? symbolForType,
                size: 42
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(surface.title)
                    .font(.headline)
                    .foregroundStyle(BellwireTheme.ink)
                    .lineLimit(2)
                if let subtitle = surface.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BellwireTheme.secondaryInk)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if surface.type == "alert",
               let badge = surface.content["badge"]?.objectValue,
               let title = badge["title"]?.stringValue {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(surfaceColor(badge["color"]?.stringValue))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        surfaceColor(badge["color"]?.stringValue).opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch surface.type {
        case "stats": StatsSurfaceContent(metrics: surface.metrics)
        case "metrics": MetricsSurfaceContent(metrics: surface.metrics)
        case "progress": ProgressSurfaceContent(surface: surface)
        case "segmented_progress": SegmentedProgressSurfaceContent(surface: surface)
        case "alert": AlertSurfaceContent(surface: surface)
        case "timer": TimerSurfaceContent(surface: surface)
        default:
            Text("Unsupported Surface")
                .font(.subheadline)
                .foregroundStyle(BellwireTheme.secondaryInk)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let project = surface.project {
                Text(project.name)
                    .lineLimit(1)
            }
            if surface.project != nil { Text("·") }
            if let date = surface.updatedDate {
                Text(date, style: .relative)
                    .monospacedDigit()
            }
            Spacer()
            if let action = surface.action,
               action.type == "open_url",
               let url = URL(string: action.url) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text(action.title)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BellwireTheme.accent)
                    .frame(minHeight: 40)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .font(.caption2)
        .foregroundStyle(BellwireTheme.secondaryInk)
    }

    private var symbolForType: String {
        switch surface.type {
        case "stats": "chart.bar.xaxis"
        case "metrics": "gauge.with.dots.needle.50percent"
        case "progress", "segmented_progress": "arrow.trianglehead.2.clockwise.rotate.90"
        case "alert": surface.content["icon"]?.objectValue?["symbol"]?.stringValue ?? "bell.badge"
        case "timer": "timer"
        default: "rectangle.3.group"
        }
    }
}

private struct StatsSurfaceContent: View {
    let metrics: [LiveSurfaceMetric]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.value.displayValue + (metric.unit ?? ""))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(BellwireTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    HStack(spacing: 6) {
                        Circle().fill(surfaceColor(metric.color)).frame(width: 6, height: 6)
                        Text(metric.label).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.secondaryInk)
                }
            }
        }
    }
}

private struct MetricsSurfaceContent: View {
    let metrics: [LiveSurfaceMetric]

    var body: some View {
        VStack(spacing: 13) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(spacing: 7) {
                    HStack {
                        Text(metric.label)
                        Spacer()
                        Text(metric.value.displayValue + (metric.unit ?? ""))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(BellwireTheme.ink)
                    }
                    .font(.subheadline)
                    .foregroundStyle(BellwireTheme.secondaryInk)
                    GeometryReader { proxy in
                        let fraction = min(max((metric.value.numberValue ?? 0) / 100, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(BellwireTheme.separator)
                            Capsule()
                                .fill(surfaceColor(metric.color))
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
    }
}

private struct ProgressSurfaceContent: View {
    let surface: LiveSurfaceRecord

    private var fraction: Double {
        if let percentage = surface.content["percentage"]?.numberValue { return percentage / 100 }
        let value = surface.content["value"]?.numberValue ?? 0
        let upper = surface.content["upperLimit"]?.numberValue ?? 1
        return upper > 0 ? value / upper : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BellwireTheme.ink)
                Spacer()
                if let value = surface.content["value"]?.numberValue,
                   let upper = surface.content["upperLimit"]?.numberValue {
                    Text("\(value.formatted()) / \(upper.formatted())")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(BellwireTheme.secondaryInk)
                }
            }
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(BellwireTheme.live)
                .scaleEffect(y: 1.6)
        }
    }
}

private struct SegmentedProgressSurfaceContent: View {
    let surface: LiveSurfaceRecord

    var body: some View {
        let steps = Int(surface.content["numberOfSteps"]?.numberValue ?? 1)
        let current = Int(surface.content["currentStep"]?.numberValue ?? 0)
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 5) {
                ForEach(0..<max(steps, 1), id: \.self) { index in
                    Capsule()
                        .fill(index < current ? BellwireTheme.live : BellwireTheme.separator)
                        .frame(height: 8)
                }
            }
            HStack {
                if let label = surface.content["stepLabel"]?.stringValue {
                    Text(label).lineLimit(1)
                }
                Spacer()
                Text("Step \(current) of \(steps)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(BellwireTheme.secondaryInk)
        }
    }
}

private struct AlertSurfaceContent: View {
    let surface: LiveSurfaceRecord

    var body: some View {
        Text(surface.content["message"]?.stringValue ?? "")
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(BellwireTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}

private struct TimerSurfaceContent: View {
    let surface: LiveSurfaceRecord

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = surface.content["durationSeconds"]?.numberValue ?? 0
            let updated = surface.updatedDate ?? .now
            let elapsed = max(context.date.timeIntervalSince(updated), 0)
            let countsDown = surface.content["countsDown"]?.boolValue != false
            let seconds = countsDown ? max(duration - elapsed, 0) : elapsed
            Text(formattedDuration(seconds))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(BellwireTheme.ink)
                .contentTransition(.numericText())
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded(.down)), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

private func surfaceColor(_ name: String?) -> Color {
    switch name {
    case "lime": Color(red: 0.47, green: 0.67, blue: 0.20)
    case "green": BellwireTheme.accent
    case "cyan": Color(red: 0.13, green: 0.58, blue: 0.66)
    case "blue": Color(red: 0.22, green: 0.43, blue: 0.78)
    case "purple": Color(red: 0.47, green: 0.35, blue: 0.69)
    case "magenta": Color(red: 0.68, green: 0.28, blue: 0.51)
    case "red": BellwireTheme.danger
    case "orange": Color(red: 0.78, green: 0.42, blue: 0.16)
    case "yellow": Color(red: 0.72, green: 0.56, blue: 0.12)
    default: BellwireTheme.secondaryInk
    }
}

import SwiftUI

enum AppRoute: Hashable {
    case event(String)
    case project(String)
}

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: ProjectFilter = .all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BellwireSpacing.roomy) {
                    projectsHeader

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { model.errorMessage = nil }
                    }

                    if model.isLoading && model.projects.isEmpty {
                        LoadingEventRows(count: 5)
                    } else if filteredProjects.isEmpty {
                        EmptyState(
                            icon: filter == .all ? "square.grid.2x2" : "line.3.horizontal.decrease.circle",
                            title: filter == .all ? "No projects connected" : "No matching projects",
                            message: filter == .all
                                ? "Generate a binding code in Settings and ask your Agent to connect a project."
                                : "Choose a different filter to see your connected projects."
                        )
                        .bellwireSurface(elevated: false)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredProjects.enumerated()), id: \.element.id) { index, project in
                                NavigationLink(value: AppRoute.project(project.id)) {
                                    ProjectListRow(
                                        project: project,
                                        latestEvent: latestEvent(for: project.id),
                                        unreadCount: unreadCount(for: project.id),
                                        isRunning: isRunning(project.id)
                                    )
                                }
                                .buttonStyle(PressableButtonStyle())
                                if index < filteredProjects.count - 1 {
                                    Divider().overlay(BellwireTheme.separator).padding(.leading, 70)
                                }
                            }
                        }
                        .padding(.horizontal, BellwireSpacing.standard)
                        .bellwireSurface()
                    }

                    VStack(alignment: .leading, spacing: BellwireSpacing.compact) {
                        SectionHeaderView(title: "Add a project")
                        HStack(alignment: .top, spacing: BellwireSpacing.small) {
                            Image(systemName: BellwireIcons.binding)
                                .foregroundStyle(BellwireTheme.accent)
                                .frame(width: 36, height: 36)
                                .background(BellwireTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ask your Agent")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(BellwireTheme.ink)
                                Text("Generate a one-time binding code in Settings, then give it to Codex, Claude Code, or another Agent.")
                                    .font(.caption)
                                    .foregroundStyle(BellwireTheme.mutedInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(BellwireSpacing.standard)
                        .overlay {
                            RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)
                                .stroke(BellwireTheme.strongSeparator, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        }
                    }
                }
                .padding(.horizontal, BellwireSpacing.roomy)
                .padding(.top, BellwireSpacing.standard)
                .padding(.bottom, BellwireSpacing.large)
            }
            .bellwirePageBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.loadDashboard() }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .project(let id): ProjectDetailView(projectID: id)
                case .event(let id): EventDetailView(eventID: id)
                }
            }
        }
    }

    private var projectsHeader: some View {
        VStack(alignment: .leading, spacing: BellwireSpacing.compact) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects")
                    .font(BellwireTypography.pageTitle)
                    .foregroundStyle(BellwireTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Picker("Project filter", selection: $filter) {
                        ForEach(ProjectFilter.allCases) { option in
                            Text(LocalizedStringKey(option.label)).tag(option)
                        }
                    }
                } label: {
                    Label {
                        Text(LocalizedStringKey(filter.label))
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BellwireTheme.accent)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Filter projects, \(filter.label) selected")
            }
            Text("\(model.projects.count) connected · \(model.projects.filter(\.isPaused).count) paused")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(BellwireTheme.mutedInk)
        }
    }

    private var filteredProjects: [ProjectSummary] {
        model.projects.filter { project in
            switch filter {
            case .all: return true
            case .active: return !project.isPaused && !isRunning(project.id)
            case .running: return isRunning(project.id)
            case .paused: return project.isPaused
            }
        }
    }

    private func latestEvent(for projectID: String) -> InboxEvent? {
        model.events.first { $0.projectId == projectID }
    }

    private func unreadCount(for projectID: String) -> Int {
        model.events.filter { $0.projectId == projectID && $0.isUnread }.count
    }

    private func isRunning(_ projectID: String) -> Bool {
        model.liveSurfaces.contains {
            $0.projectId == projectID && ["progress", "segmented_progress", "timer"].contains($0.type)
        }
    }
}

private enum ProjectFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case running
    case paused

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private struct ProjectListRow: View {
    let project: ProjectSummary
    let latestEvent: InboxEvent?
    let unreadCount: Int
    let isRunning: Bool

    var body: some View {
        HStack(spacing: BellwireSpacing.small) {
            ProjectAvatarView(name: project.name, icon: project.icon, size: 46, logoURL: project.logoUrl.flatMap(URL.init(string:)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: BellwireSpacing.compact) {
                    Text(project.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BellwireTheme.ink)
                        .lineLimit(1)
                    if project.isPaused {
                        StatusBadgeView(text: "Paused", color: BellwireTheme.mutedInk, showsDot: false)
                    }
                }
                Text(project.category.capitalized + " · " + latestDescription)
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.mutedInk)
                    .lineLimit(1)
            }
            Spacer(minLength: BellwireSpacing.compact)
            if isRunning {
                StatusBadgeView(text: "Running", color: BellwireTheme.live)
            } else if unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(BellwireTheme.accentInk)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(BellwireTheme.accent, in: Capsule())
                    .accessibilityLabel("\(unreadCount) unread events")
            } else {
                Circle()
                    .fill(project.isPaused ? BellwireTheme.mutedInk : BellwireTheme.success)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(project.isPaused ? "Paused" : "Active")
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var latestDescription: String {
        guard let latestEvent else { return "No recent events" }
        return latestEvent.displayTitle
    }
}

struct EventsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var filter: EventFilter

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BellwireSpacing.roomy) {
                    VStack(alignment: .leading, spacing: BellwireSpacing.standard) {
                        HStack(alignment: .firstTextBaseline, spacing: BellwireSpacing.standard) {
                            Text("Events")
                                .font(BellwireTypography.pageTitle)
                                .foregroundStyle(BellwireTheme.ink)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button {
                                Task {
                                    if await model.markAllRead() > 0 { BellwireHaptics.success() }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if model.isMarkingAllRead {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "checkmark.circle")
                                    }
                                    Text("Mark all read")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BellwireTheme.accent)
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(model.unreadCount == 0 || model.isMarkingAllRead)
                            .opacity(model.unreadCount == 0 ? 0.42 : 1)
                            .accessibilityHint("Marks every unread event as read")
                        }
                        Picker("Event filter", selection: $filter) {
                            ForEach(EventFilter.allCases) { option in
                                Text(LocalizedStringKey(option.label)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { model.errorMessage = nil }
                    }

                    if model.isLoading && model.events.isEmpty {
                        LoadingEventRows(count: 6)
                    } else if filteredEvents.isEmpty {
                        EmptyState(
                            icon: filter == .all ? "bolt" : "line.3.horizontal.decrease.circle",
                            title: filter == .all ? "No events yet" : "No matching events",
                            message: filter == .all
                                ? "Events appear after a connected project sends its first signal."
                                : "Choose another filter to view the rest of your event history."
                        )
                        .bellwireSurface(elevated: false)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredEvents.enumerated()), id: \.element.id) { index, event in
                                NavigationLink(value: AppRoute.event(event.id)) {
                                    EventRow(event: event)
                                }
                                .buttonStyle(PressableButtonStyle())
                                if index < filteredEvents.count - 1 {
                                    Divider().overlay(BellwireTheme.separator).padding(.leading, 52)
                                }
                            }
                        }
                        .padding(.horizontal, BellwireSpacing.standard)
                        .bellwireSurface()
                    }
                }
                .padding(.horizontal, BellwireSpacing.roomy)
                .padding(.top, BellwireSpacing.standard)
                .padding(.bottom, BellwireSpacing.large)
            }
            .bellwirePageBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.loadDashboard() }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .project(let id): ProjectDetailView(projectID: id)
                case .event(let id): EventDetailView(eventID: id)
                }
            }
        }
    }

    private var filteredEvents: [InboxEvent] {
        model.events.filter { event in
            switch filter {
            case .all: return true
            case .unread: return event.isUnread
            case .failed: return event.status == "failed"
            }
        }
    }
}

enum EventFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case failed

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct InboxView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var path: [AppRoute] = []
    let onOpenEvents: (_ preferUnread: Bool) -> Void

    init(onOpenEvents: @escaping (_ preferUnread: Bool) -> Void = { _ in }) {
        self.onOpenEvents = onOpenEvents
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BellwireSpacing.section) {
                    homeHeader
                    digestStrip

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { model.errorMessage = nil }
                    }

                    liveSection
                    eventsSection
                }
                .padding(.horizontal, BellwireSpacing.page)
                .padding(.top, BellwireSpacing.standard)
                .padding(.bottom, BellwireSpacing.large)
            }
            .bellwirePageBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.loadDashboard() }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .event(let id): EventDetailView(eventID: id)
                case .project(let id): ProjectDetailView(projectID: id)
                }
            }
            .onChange(of: model.pendingEventID) { _, newValue in
                guard let id = newValue else { return }
                path.append(.event(id))
                model.pendingEventID = nil
            }
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .center, spacing: BellwireSpacing.standard) {
            VStack(alignment: .leading, spacing: 5) {
                Text(BellwireDateFormatting.headerDate(.now, locale: locale))
                    .bellwireTechnicalLabel()
                Text(LocalizedStringKey(greeting))
                    .font(BellwireTypography.pageTitle)
                    .tracking(-0.5)
                    .foregroundStyle(BellwireTheme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button {
                BellwireHaptics.selection()
                onOpenEvents(model.unreadCount > 0)
            } label: {
                Image(systemName: BellwireIcons.notification)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BellwireTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(BellwireTheme.surface, in: Circle())
                    .overlay(Circle().stroke(BellwireTheme.separator, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if model.unreadCount > 0 {
                            Circle()
                                .fill(BellwireTheme.accent)
                                .frame(width: 9, height: 9)
                                .overlay {
                                    Circle().stroke(BellwireTheme.background, lineWidth: 2)
                                }
                                .offset(x: -1, y: 1)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(model.unreadCount > 0 ? "Open unread events" : "Open events")
            .accessibilityValue(model.unreadCount > 0 ? "\(model.unreadCount) unread" : "No unread events")
            .accessibilityHint("Opens the Events tab")
        }
    }

    private var digestStrip: some View {
        HStack(spacing: BellwireSpacing.standard) {
            DigestMetricView(value: model.todayCount, label: "events")
            Rectangle().fill(BellwireTheme.separator).frame(width: 1, height: 38)
            DigestMetricView(value: model.unreadCount, label: "unread")
            Rectangle().fill(BellwireTheme.separator).frame(width: 1, height: 38)
            DigestMetricView(value: runningSurfaceCount, label: "running", isAccented: true)
        }
        .padding(BellwireSpacing.standard)
        .background {
            RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)
                .fill(BellwireTheme.surface)
                .overlay(BellwireTheme.amberGlow.clipShape(RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)))
                .overlay(BellwireTheme.amberGlowLeading.clipShape(RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)
                .stroke(BellwireTheme.separator, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(
                title: "Live surfaces",
                hint: model.liveSurfaces.isEmpty ? nil : "\(model.liveSurfaces.count) active"
            )
            if model.isLoading && model.liveSurfaces.isEmpty {
                LoadingEventRows(count: 2)
            } else if model.liveSurfaces.isEmpty {
                EmptyState(
                    icon: "waveform.path.ecg",
                    title: "No live surfaces",
                    message: "Live progress, metrics, and alerts appear here when an Agent publishes them."
                )
                .bellwireSurface(elevated: false)
            } else {
                LiveSurfacesSection(surfaces: model.liveSurfaces, showsHeader: false)
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Recent events", hint: model.events.isEmpty ? nil : "Latest")

            if model.isLoading && model.events.isEmpty {
                LoadingEventRows()
            } else if model.events.isEmpty {
                EmptyState(
                    icon: "tray",
                    title: "No events yet",
                    message: "Generate a binding code in Settings, then ask your Agent to connect the first project."
                )
                .bellwireSurface(elevated: false)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.events.prefix(6).enumerated()), id: \.element.id) { index, event in
                        NavigationLink(value: AppRoute.event(event.id)) {
                            EventRow(event: event)
                        }
                        .buttonStyle(PressableButtonStyle())
                        if index < min(model.events.count, 6) - 1 {
                            Divider().overlay(BellwireTheme.separator).padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, BellwireSpacing.standard)
                .bellwireSurface()
            }
        }
    }

    private var runningSurfaceCount: Int {
        model.liveSurfaces.filter { ["progress", "segmented_progress", "timer"].contains($0.type) }.count
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default: return "Good evening."
        }
    }
}

struct EventRow: View {
    let event: InboxEvent
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: BellwireSpacing.small) {
            ProjectAvatarView(
                name: event.project.name,
                icon: event.project.icon,
                size: 36,
                logoURL: event.project.logoUrl.flatMap(URL.init(string:))
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if event.isUnread {
                        Circle().fill(BellwireTheme.accent).frame(width: 6, height: 6)
                    }
                    Text(event.displayTitle)
                        .font(.subheadline.weight(event.isUnread ? .semibold : .medium))
                        .foregroundStyle(BellwireTheme.ink)
                        .lineLimit(1)
                    if event.status == "failed" {
                        StatusBadgeView(text: "Failed", color: BellwireTheme.danger, showsDot: false)
                    }
                }
                Text(event.preview.isEmpty ? event.project.name : event.preview)
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.mutedInk)
                    .lineLimit(1)
            }
            Spacer(minLength: BellwireSpacing.compact)
            if let date = event.receivedDate {
                Text(BellwireDateFormatting.relative(date, locale: locale))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(BellwireTheme.mutedInk)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.isUnread ? "Unread, " : "")\(event.displayTitle), \(event.preview), \(event.project.name)")
    }
}

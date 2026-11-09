import AppKit
import Combine
import SwiftUI

/// Proportional, centered macOS Desktop Application interface (`MainDashboardView`).
/// Uses a clean, max-width-constrained (`maxWidth: 720`) layout so cards never stretch
/// awkwardly across ultra-wide or large desktop monitors.
@MainActor
public struct MainDashboardView: View {
    @Bindable var manager: AutoHideManager

    @State private var customInput: String = ""
    @State private var selectedSection: NavigationSection = .overview

    public enum NavigationSection: String, CaseIterable, Identifiable {
        case overview = "Dashboard"
        case runningApps = "Running Apps"
        case exclusions = "Exclusions"
        case activityLog = "Activity Log"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .overview: return "slider.horizontal.2.square.on.square"
            case .runningApps: return "macwindow.on.rectangle"
            case .exclusions: return "shield.lefthalf.filled"
            case .activityLog: return "clock.arrow.circlepath"
            }
        }

        public var subtitle: String {
            switch self {
            case .overview: return "Configure Auto-Hide, Auto-Quit, and smart protections"
            case .runningApps: return "Live inactivity countdowns and manual app controls"
            case .exclusions: return "Apps that will never be automatically hidden or quit"
            case .activityLog: return "Plain-English history and one-click diagnostic log export"
            }
        }
    }

    private let uiRefreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    public init(manager: AutoHideManager) {
        self.manager = manager
    }

    public var body: some View {
        NavigationSplitView {
            sidebarNavigation
                .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 250)
        } detail: {
            detailCanvas
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540, idealHeight: 620)
        .onAppear {
            manager.refreshRunningApps()
            manager.refreshLaunchAtLoginStatus()
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
        }
        .onReceive(uiRefreshTimer) { _ in
            guard selectedSection == .runningApps,
                  NSApplication.shared.windows.contains(where: { $0.title == "AutoHide" && $0.isVisible }) else {
                return
            }
            manager.refreshRunningApps()
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .runningApps {
                manager.refreshRunningApps()
            }
        }
    }

    // MARK: - Left Sidebar Navigation (Clean Apple System Settings Style)

    private var sidebarNavigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App Identity & Master Switch Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let appIcon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 38, height: 38)
                            .opacity(manager.isEnabled && !manager.isTemporarilyPaused ? 1.0 : 0.55)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AutoHide")
                            .font(.system(size: 15, weight: .bold, design: .rounded))

                        HStack(spacing: 5) {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 7, height: 7)
                            Text(statusSubtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $manager.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                // Quick Action Buttons in Sidebar
                HStack(spacing: 6) {
                    Button {
                        manager.hideAllBackgroundAppsNow()
                    } label: {
                        Label("Hide Now", systemImage: "eye.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)

                    Button {
                        manager.togglePauseForOneHour()
                    } label: {
                        Label(
                            manager.isTemporarilyPaused ? "Resume" : "Pause 1h",
                            systemImage: manager.isTemporarilyPaused ? "play.fill" : "cup.and.saucer.fill"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!manager.isEnabled)
                }
            }
            .padding(12)

            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            // Navigation List
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    HStack {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let badge = badgeCount(for: section) {
                            Text("\(badge)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom Status Bar in Sidebar
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isAccessibilityTrusted ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(manager.isAccessibilityTrusted ? "Accessibility Ready" : "Accessibility Required")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !manager.isAccessibilityTrusted {
                    Button("Grant") {
                        manager.refreshAccessibilityTrustStatus(promptIfNeeded: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.mini)
                }
            }
            .padding(12)
        }
    }

    private func badgeCount(for section: NavigationSection) -> Int? {
        switch section {
        case .overview:
            return nil
        case .runningApps:
            return manager.runningRegularApps.count
        case .exclusions:
            return manager.whitelistedBundleIDs.count
        case .activityLog:
            return manager.activityLogs.isEmpty ? nil : manager.activityLogs.count
        }
    }

    private var statusDotColor: Color {
        guard manager.isEnabled else { return Color.secondary.opacity(0.5) }
        return manager.isTemporarilyPaused ? .orange : .green
    }

    private var statusSubtitle: String {
        guard manager.isEnabled else { return "Disabled" }
        if let until = manager.pausedUntilDate, Date.now < until {
            let remaining = manager.formatFriendlyDuration(until.timeIntervalSinceNow)
            return "Snoozed (\(remaining))"
        }
        return "Active"
    }

    // MARK: - Right Detail Canvas (Centered, Max-Width Constrained for Large Screens)

    private var detailCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Page Title Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedSection.rawValue)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(selectedSection.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    headerToolbarActions
                }
                .padding(.bottom, 4)

                // Section Content
                switch selectedSection {
                case .overview:
                    overviewSettingsContent
                case .runningApps:
                    runningAppsContent
                case .exclusions:
                    exclusionsContent
                case .activityLog:
                    activityLogContent
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var headerToolbarActions: some View {
        switch selectedSection {
        case .overview:
            EmptyView()
        case .runningApps, .exclusions:
            Button {
                manager.refreshRunningApps()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .controlSize(.regular)

        case .activityLog:
            HStack(spacing: 8) {
                Button {
                    manager.openDiagnosticLogFile()
                } label: {
                    Label("Open Log File", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.regular)

                Button {
                    manager.revealDiagnosticLogInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.regular)

                if !manager.activityLogs.isEmpty {
                    Button("Clear") {
                        manager.clearLogs()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: - Section 1: Dashboard Overview (Clean Settings Cards)

    private var overviewSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !manager.isAccessibilityTrusted {
                cardContainer(tintColor: .orange) {
                    HStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 22))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Accessibility Permission Required")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text("macOS requires Accessibility trust so AutoHide can reliably hide background applications.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Grant Access") {
                            manager.refreshAccessibilityTrustStatus(promptIfNeeded: true)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                    }
                }
            }

            // 1. Auto-Hide Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Hide Inactive Apps")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Automatically hides background windows after inactivity")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "eye.slash.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.accentColor)
                        }

                        Spacer()

                        Toggle("", isOn: $manager.isAutoHideEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!manager.isEnabled)
                    }

                    Divider()

                    HStack {
                        Text("Hide inactive apps after:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Picker("", selection: $manager.timeoutSeconds) {
                            ForEach(TimeoutPreset.allCases) { preset in
                                Text(preset.label).tag(preset.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                        .disabled(!manager.isEnabled || !manager.isAutoHideEnabled)
                    }
                }
            }

            // 2. Auto-Quit Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Quit Inactive Apps")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Gracefully quits apps left unused for extended periods")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.red)
                        }

                        Spacer()

                        Toggle("", isOn: $manager.isAutoQuitEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!manager.isEnabled)
                    }

                    Divider()

                    HStack {
                        Text("Quit inactive apps after:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Picker("", selection: $manager.quitTimeoutSeconds) {
                            ForEach(QuitTimeoutPreset.allCases) { preset in
                                Text(preset.label).tag(preset.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                        .disabled(!manager.isEnabled || !manager.isAutoQuitEnabled)
                    }

                    Divider()

                    Toggle("Ask for confirmation before quitting an app", isOn: $manager.confirmBeforeAutoQuit)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .disabled(!manager.isEnabled || !manager.isAutoQuitEnabled)
                }
            }

            // 3. Smart Protections Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smart Protections & Sleep Awareness")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Prevents interruptions while you work, watch media, or close your lid")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.purple)
                    }

                    Divider()

                    Toggle("Keep most recent background app visible (great for side-by-side work)", isOn: $manager.keepPreviousAppVisible)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .disabled(!manager.isEnabled)

                    Toggle("Protect apps playing audio, video, or on calls (Spotify, Zoom, VLC, etc.)", isOn: $manager.protectActiveMediaApps)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .disabled(!manager.isEnabled)

                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 12))
                        Text("All timers automatically pause when your Mac sleeps, screen turns off, locks, or runs a screensaver.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }

            // 4. App Presence & Startup Card
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App Presence & Startup")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Choose where AutoHide appears on your Mac")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "menubar.dock.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.teal)
                    }

                    Divider()

                    HStack(spacing: 24) {
                        Toggle("Show in Dock & App Switcher", isOn: $manager.showInDock)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12.5))

                        Toggle("Show Icon in Menu Bar", isOn: $manager.showInMenuBar)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12.5))

                        Spacer()

                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { manager.launchAtLoginEnabled },
                                set: { manager.setLaunchAtLogin($0) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                    }

                    if let error = manager.launchAtLoginError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Section 2: Running Apps & Live Timers

    private var runningAppsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.runningRegularApps.isEmpty {
                cardContainer {
                    ContentUnavailableView(
                        "No Background Applications",
                        systemImage: "macwindow",
                        description: Text("Other open macOS applications will appear here with their live inactivity timers.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                ForEach(manager.runningRegularApps) { app in
                    dashboardAppRow(for: app)
                }
            }
        }
    }

    private func dashboardAppRow(for app: RunningAppInfo) -> some View {
        let isWhitelisted = manager.whitelistedBundleIDs.contains {
            $0.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame ||
            $0.caseInsensitiveCompare(app.localizedName) == .orderedSame
        }

        return cardContainer {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 24))
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.localizedName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        if app.isHidden {
                            Text("HIDDEN")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                    }
                    Text(app.bundleIdentifier)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(isWhitelisted ? "Excluded" : countdownLabel(for: app))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isWhitelisted ? .secondary : (app.isHidden ? .secondary : .primary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))

                HStack(spacing: 6) {
                    Button {
                        if isWhitelisted {
                            manager.removeWhitelistEntry(app.bundleIdentifier)
                        } else {
                            manager.addWhitelistEntry(app.bundleIdentifier)
                        }
                    } label: {
                        Label(
                            isWhitelisted ? "Excluded" : "Exclude",
                            systemImage: isWhitelisted ? "shield.slash.fill" : "shield.fill"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    if !app.isHidden {
                        Button {
                            manager.manuallyHideApp(app)
                        } label: {
                            Label("Hide", systemImage: "eye.slash")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }

                    Button(role: .destructive) {
                        manager.manuallyQuitApp(app)
                    } label: {
                        Label("Quit", systemImage: "xmark.octagon.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }

    private func countdownLabel(for app: RunningAppInfo) -> String {
        if app.hasActivePowerAssertion {
            return "Playing Media / Call"
        }
        if app.isProtectedMostRecent {
            return "Kept Visible (Recent)"
        }
        guard let elapsed = app.elapsedInactiveSeconds else {
            return "Active Now"
        }
        if app.isHidden {
            if manager.isAutoQuitEnabled {
                let remQuit = max(0, TimeInterval(manager.quitTimeoutSeconds) - elapsed)
                return remQuit > 0 ? "Quits in \(manager.formatFriendlyDuration(remQuit))" : "Hidden"
            }
            return "Hidden"
        }
        if !manager.isAutoHideEnabled {
            if manager.isAutoQuitEnabled {
                let remQuit = max(0, TimeInterval(manager.quitTimeoutSeconds) - elapsed)
                return remQuit > 0 ? "Quits in \(manager.formatFriendlyDuration(remQuit))" : "Quitting…"
            }
            return "Auto-Hide Off"
        }
        let remHide = max(0, TimeInterval(manager.timeoutSeconds) - elapsed)
        return remHide > 0 ? "Hides in \(manager.formatFriendlyDuration(remHide))" : "Hiding soon…"
    }

    // MARK: - Section 3: Exclusions Manager

    private var exclusionsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardContainer {
                HStack(spacing: 10) {
                    TextField("Enter Bundle ID (e.g. com.apple.Safari) or App Name…", text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .onSubmit {
                            submitCustomInput()
                        }

                    Button("Add Exclusion") {
                        submitCustomInput()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Menu {
                        let candidates = availableAppsToWhitelist
                        if candidates.isEmpty {
                            Text("All running apps are already excluded")
                        } else {
                            ForEach(candidates) { app in
                                Button {
                                    manager.addWhitelistEntry(app.bundleIdentifier)
                                } label: {
                                    Text("\(app.localizedName) (\(app.bundleIdentifier))")
                                }
                            }
                        }
                    } label: {
                        Label("Pick Running App", systemImage: "plus.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .fixedSize()
                }
            }

            ForEach(manager.whitelistedBundleIDs, id: \.self) { entry in
                let matchedApp = manager.runningRegularApps.first {
                    $0.bundleIdentifier.caseInsensitiveCompare(entry) == .orderedSame ||
                    $0.localizedName.caseInsensitiveCompare(entry) == .orderedSame
                }

                cardContainer {
                    HStack(spacing: 12) {
                        if let icon = matchedApp?.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(matchedApp?.localizedName ?? entry)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            if matchedApp != nil {
                                Text(entry)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if let matchedApp, entry.caseInsensitiveCompare("com.apple.finder") != .orderedSame {
                            Button(role: .destructive) {
                                manager.manuallyQuitApp(matchedApp)
                            } label: {
                                Label("Quit App", systemImage: "xmark.octagon.fill")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }

                        if entry.caseInsensitiveCompare("com.apple.finder") == .orderedSame {
                            Text("Protected System App")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        } else {
                            Button {
                                manager.removeWhitelistEntry(entry)
                            } label: {
                                Label("Remove", systemImage: "trash")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var availableAppsToWhitelist: [RunningAppInfo] {
        let lowerWhitelist = Set(manager.whitelistedBundleIDs.map { $0.lowercased() })
        return manager.runningRegularApps.filter { app in
            !lowerWhitelist.contains(app.bundleIdentifier.lowercased()) &&
            !lowerWhitelist.contains(app.localizedName.lowercased())
        }
    }

    private func submitCustomInput() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.addWhitelistEntry(trimmed)
        customInput = ""
    }

    // MARK: - Section 4: Activity Log

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private var activityLogContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.activityLogs.isEmpty {
                cardContainer {
                    ContentUnavailableView(
                        "No Activity Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Every hide, quit, setting change, and sleep/wake event will be logged here in plain English.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                ForEach(manager.activityLogs) { entry in
                    cardContainer {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: iconForLogLevel(entry.level))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colorForLogLevel(entry.level))
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.userFriendlyMessage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)

                                if !entry.technicalDetail.isEmpty {
                                    Text(entry.technicalDetail)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Text(Self.logTimeFormatter.string(from: entry.timestamp))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func iconForLogLevel(_ level: ActivityLogEntry.Level) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .action: return "checkmark.circle.fill"
        }
    }

    private func colorForLogLevel(_ level: ActivityLogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .action: return .green
        }
    }

    // MARK: - Reusable Card Container

    private func cardContainer<Content: View>(
        tintColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((tintColor ?? .primary).opacity(0.10), lineWidth: 1)
            }
    }
}

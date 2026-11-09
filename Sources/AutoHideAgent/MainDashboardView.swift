import AppKit
import Combine
import SwiftUI

/// Native macOS System Settings style Desktop Window (`MainDashboardView`).
/// - Left sidebar uses native `.listStyle(.sidebar)` navigation without cramped action buttons.
/// - Detail pane uses clean System-Settings grouped rows (`maxWidth: 660`) with switches and menus
///   instead of tiny checkboxes or cluttered custom badges.
@MainActor
public struct MainDashboardView: View {
    @Bindable var manager: AutoHideManager

    @State private var customInput: String = ""
    @State private var selectedSection: NavigationSection = .overview
    @State private var appSearchText: String = ""
    @State private var logSearchText: String = ""

    public enum NavigationSection: String, CaseIterable, Identifiable {
        case overview = "General"
        case runningApps = "Background Apps"
        case exclusions = "Excluded Apps"
        case activityLog = "Activity Log"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .overview: return "gearshape"
            case .runningApps: return "macwindow.on.rectangle"
            case .exclusions: return "shield.lefthalf.filled"
            case .activityLog: return "clock.arrow.circlepath"
            }
        }
    }

    private let uiRefreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    public init(manager: AutoHideManager) {
        self.manager = manager
    }

    public var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 195, ideal: 205, max: 225)
        } detail: {
            detailCanvas
        }
        .frame(minWidth: 740, idealWidth: 820, minHeight: 520, idealHeight: 580)
        .onAppear {
            manager.refreshRunningApps()
            manager.refreshLaunchAtLoginStatus()
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
        }
        .onReceive(uiRefreshTimer) { _ in
            guard NSApplication.shared.windows.contains(where: { $0.title == "AutoHide" && $0.isVisible }) else {
                return
            }
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
            if selectedSection == .runningApps || selectedSection == .overview {
                manager.refreshRunningApps()
            }
        }
        .onChange(of: selectedSection) { _, _ in
            manager.refreshRunningApps()
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
        }
    }

    // MARK: - 1. Native macOS System Settings Sidebar

    private var sidebarView: some View {
        List(NavigationSection.allCases, selection: $selectedSection) { section in
            NavigationLink(value: section) {
                Label(section.rawValue, systemImage: section.icon)
                    .font(.system(size: 13))
            }
            .badge(badgeCount(for: section))
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarStatusFooter
        }
    }

    private func badgeCount(for section: NavigationSection) -> Int {
        switch section {
        case .overview:
            return 0
        case .runningApps:
            return manager.runningRegularApps.count
        case .exclusions:
            return manager.whitelistedBundleIDs.count
        case .activityLog:
            return manager.activityLogs.count
        }
    }

    private var sidebarStatusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7.5, height: 7.5)

            Text(statusSummaryText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var statusDotColor: Color {
        guard manager.isEnabled else { return Color.secondary.opacity(0.45) }
        return manager.isTemporarilyPaused ? .orange : .green
    }

    private var statusSummaryText: String {
        guard manager.isEnabled else { return "AutoHide is Off" }
        if let until = manager.pausedUntilDate, Date.now < until {
            return "Paused (\(manager.formatFriendlyDuration(until.timeIntervalSinceNow)))"
        }
        return "Active • \(manager.visibleBackgroundAppsCount) visible"
    }

    // MARK: - 2. Centered System Settings Detail Canvas (maxWidth: 650)

    private var detailCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selectedSection {
                case .overview:
                    generalSettingsSection
                case .runningApps:
                    runningAppsSection
                case .exclusions:
                    exclusionsSection
                case .activityLog:
                    activityLogSection
                }
            }
            .frame(maxWidth: 650, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab 1: General Settings (System Settings Style)

    private var generalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Top Master Status & Instant Actions Card (like macOS Wi-Fi / Bluetooth header card)
            settingsGroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        if let appIcon = NSApplication.shared.applicationIconImage {
                            Image(nsImage: appIcon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 40, height: 40)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AutoHide")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text(masterHeroSubtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $manager.isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    Divider()
                        .padding(.horizontal, 14)

                    // Clear, self-explanatory manual actions row
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Other Open Apps")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)

                            Text(
                                manager.visibleBackgroundAppsCount > 0
                                    ? "\(manager.visibleBackgroundAppsCount) background \(manager.visibleBackgroundAppsCount == 1 ? "app is" : "apps are") currently visible behind your active window."
                                    : "All background apps are currently hidden."
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 8) {
                            Button {
                                manager.togglePauseForOneHour()
                            } label: {
                                Label(
                                    manager.isTemporarilyPaused ? "Resume" : "Pause 1h",
                                    systemImage: manager.isTemporarilyPaused ? "play.fill" : "pause.fill"
                                )
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(!manager.isEnabled)

                            Button {
                                manager.hideAllBackgroundAppsNow()
                            } label: {
                                Label(
                                    manager.visibleBackgroundAppsCount > 0
                                        ? "Hide \(manager.visibleBackgroundAppsCount) \(manager.visibleBackgroundAppsCount == 1 ? "App" : "Apps") Now"
                                    : "Hide Others Now",
                                    systemImage: "eye.slash.fill"
                                )
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }

            // Accessibility Permission Card (Live updating + 1-click Reset if macOS cached an older build)
            accessibilityStatusGroup

            // Inactivity Timers Group
            VStack(alignment: .leading, spacing: 6) {
                sectionGroupTitle("Inactivity Timers")

                settingsGroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        // Row 1: Auto-Hide
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Hide Inactive Apps")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Automatically hide background windows after they haven't been used for:")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: $manager.timeoutSeconds) {
                                ForEach(TimeoutPreset.allCases) { preset in
                                    Text(preset.fullName).tag(preset.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .disabled(!manager.isEnabled || !manager.isAutoHideEnabled)

                            Toggle("", isOn: $manager.isAutoHideEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(!manager.isEnabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.horizontal, 14)

                        // Row 2: Auto-Quit
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Quit Hidden Apps")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Gracefully quit apps that remain unused in the background for:")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: $manager.quitTimeoutSeconds) {
                                ForEach(QuitTimeoutPreset.allCases) { preset in
                                    Text(preset.fullName).tag(preset.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .disabled(!manager.isEnabled || !manager.isAutoQuitEnabled)

                            Toggle("", isOn: $manager.isAutoQuitEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(!manager.isEnabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.horizontal, 14)

                        // Row 3: Ask Confirmation Before Quitting
                        settingsToggleRow(
                            title: "Ask Confirmation Before Auto-Quitting",
                            subtitle: "Show a confirmation dialog before quitting an inactive app so you never lose work.",
                            isOn: $manager.confirmBeforeAutoQuit,
                            disabled: !manager.isEnabled || !manager.isAutoQuitEnabled
                        )
                    }
                }
            }

            // Smart Protections Group
            VStack(alignment: .leading, spacing: 6) {
                sectionGroupTitle("Smart Protections")

                settingsGroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsToggleRow(
                            title: "Keep Most Recent Background App Visible",
                            subtitle: "Leaves your second-most-recent app unhidden — ideal when working side-by-side between two apps.",
                            isOn: $manager.keepPreviousAppVisible,
                            disabled: !manager.isEnabled
                        )

                        Divider().padding(.horizontal, 14)

                        settingsToggleRow(
                            title: "Protect Audio, Video & Active Calls",
                            subtitle: "Never hide or quit apps actively playing media or in a meeting (Spotify, Zoom, FaceTime, VLC).",
                            isOn: $manager.protectActiveMediaApps,
                            disabled: !manager.isEnabled
                        )

                        Divider().padding(.horizontal, 14)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pause Timers When Screen is Dark or Locked")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Inactivity countdowns automatically freeze when your display turns off, screensaver starts, or Mac sleeps.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Always On")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                }
            }

            // App Presence & Startup Group
            VStack(alignment: .leading, spacing: 6) {
                sectionGroupTitle("App Presence & Startup")

                settingsGroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsToggleRow(
                            title: "Show AutoHide in Menu Bar",
                            subtitle: "Display the quick Control Center panel icon in your top macOS menu bar.",
                            isOn: $manager.showInMenuBar
                        )

                        Divider().padding(.horizontal, 14)

                        settingsToggleRow(
                            title: "Show AutoHide in Dock",
                            subtitle: "Keep AutoHide visible in the macOS Dock and Command-Tab app switcher.",
                            isOn: $manager.showInDock
                        )

                        Divider().padding(.horizontal, 14)

                        settingsToggleRow(
                            title: "Launch AutoHide at Login",
                            subtitle: "Start automatically in the background when you sign in to your Mac.",
                            isOn: Binding(
                                get: { manager.launchAtLoginEnabled },
                                set: { manager.setLaunchAtLogin($0) }
                            )
                        )
                    }
                }
            }
        }
    }

    private var masterHeroSubtitle: String {
        guard manager.isEnabled else {
            return "Automation is currently turned off."
        }
        if let until = manager.pausedUntilDate, Date.now < until {
            return "Timers paused for \(manager.formatFriendlyDuration(until.timeIntervalSinceNow))."
        }
        return "Watching \(manager.runningRegularApps.count) open apps (\(manager.visibleBackgroundAppsCount) visible, \(manager.hiddenBackgroundAppsCount) hidden)."
    }

    private var accessibilityStatusGroup: some View {
        settingsGroupBox {
            HStack(spacing: 12) {
                Image(systemName: manager.isAccessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(manager.isAccessibilityTrusted ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        manager.isAccessibilityTrusted
                            ? "Accessibility Permission Active"
                            : "Accessibility Permission Required"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                    Text(
                        manager.isAccessibilityTrusted
                            ? "macOS allows AutoHide to hide background applications automatically."
                            : "Click \"Grant Access\" and enable AutoHide in System Settings → Privacy & Security → Accessibility."
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if !manager.isAccessibilityTrusted {
                    HStack(spacing: 8) {
                        Button("Reset Cache") {
                            manager.resetAndPromptAccessibilityPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Clears stale macOS permission cache from older builds and prompts freshly")

                        Button("Grant Access…") {
                            manager.refreshAccessibilityTrustStatus(promptIfNeeded: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.regular)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("Enabled")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Tab 2: Running Background Apps

    private var runningAppsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Applications (\(manager.runningRegularApps.count))")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(manager.visibleBackgroundAppsCount) visible • \(manager.hiddenBackgroundAppsCount) hidden")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Filter apps…", text: $appSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button {
                    manager.hideAllBackgroundAppsNow()
                } label: {
                    Label("Hide All Visible Now", systemImage: "eye.slash.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            settingsGroupBox {
                let filteredApps = manager.runningRegularApps.filter { app in
                    appSearchText.trimmingCharacters(in: .whitespaces).isEmpty ||
                    app.localizedName.localizedCaseInsensitiveContains(appSearchText) ||
                    app.bundleIdentifier.localizedCaseInsensitiveContains(appSearchText)
                }

                if filteredApps.isEmpty {
                    Text("No matching background applications.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                            runningAppRow(for: app)
                            if index < filteredApps.count - 1 {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    private func runningAppRow(for app: RunningAppInfo) -> some View {
        let isWhitelisted = manager.whitelistedBundleIDs.contains {
            $0.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame ||
            $0.caseInsensitiveCompare(app.localizedName) == .orderedSame
        }

        return HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .opacity(app.isHidden ? 0.55 : 1.0)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 20))
                    .frame(width: 26, height: 26)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(app.localizedName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(app.isHidden ? .secondary : .primary)

                    if app.isHidden {
                        Text("Hidden")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }

                Text(appStatusDescription(for: app, isWhitelisted: isWhitelisted))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isWhitelisted ? "Excluded" : "Exclude") {
                if isWhitelisted {
                    manager.removeWhitelistEntry(app.bundleIdentifier)
                } else {
                    manager.addWhitelistEntry(app.bundleIdentifier)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !app.isHidden {
                Button("Hide") {
                    manager.manuallyHideApp(app)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Quit") {
                manager.manuallyQuitApp(app)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func appStatusDescription(for app: RunningAppInfo, isWhitelisted: Bool) -> String {
        if isWhitelisted { return "Excluded from Auto-Hide & Auto-Quit" }
        if app.hasActivePowerAssertion { return "Protected (Active Media / Call)" }
        if app.isProtectedMostRecent { return "Protected (Most Recent Background App)" }
        guard let elapsed = app.elapsedInactiveSeconds else { return "Active (Frontmost)" }

        if app.isHidden {
            if manager.isAutoQuitEnabled {
                let remQuit = max(0, TimeInterval(manager.quitTimeoutSeconds) - elapsed)
                return remQuit > 0 ? "Auto-Quit in \(manager.formatFriendlyDuration(remQuit))" : "Eligible for Auto-Quit"
            }
            return "Hidden (\(manager.formatFriendlyDuration(elapsed)) inactive)"
        }

        if manager.isAutoHideEnabled {
            let remHide = max(0, TimeInterval(manager.timeoutSeconds) - elapsed)
            return remHide > 0 ? "Auto-Hide in \(manager.formatFriendlyDuration(remHide))" : "Eligible to hide"
        }
        return "Visible (\(manager.formatFriendlyDuration(elapsed)) inactive)"
    }

    // MARK: - Tab 3: Exclusions

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Excluded Applications (\(manager.whitelistedBundleIDs.count))")
                    .font(.system(size: 15, weight: .semibold))
                Text("Apps in this list will never be automatically hidden or quit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Add app name or bundle ID (e.g. com.apple.Music)…", text: $customInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addCustomExclusion()
                    }

                Button("Add Exclusion") {
                    addCustomExclusion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            settingsGroupBox {
                if manager.whitelistedBundleIDs.isEmpty {
                    Text("No excluded apps.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(manager.whitelistedBundleIDs.enumerated()), id: \.element) { index, item in
                            HStack {
                                Image(systemName: "shield.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(item)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                if item.lowercased() != "com.apple.finder" {
                                    Button("Remove") {
                                        manager.removeWhitelistEntry(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                } else {
                                    Text("System Default")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            if index < manager.whitelistedBundleIDs.count - 1 {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    private func addCustomExclusion() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.addWhitelistEntry(trimmed)
        customInput = ""
    }

    // MARK: - Tab 4: Activity Log

    private var activityLogSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Activity")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Plain-English history plus persistent technical log file.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Log File…") {
                    manager.openDiagnosticLogFile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Reveal in Finder") {
                    manager.revealDiagnosticLogInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Clear") {
                    manager.clearLogs()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manager.activityLogs.isEmpty)
            }

            settingsGroupBox {
                if manager.activityLogs.isEmpty {
                    Text("No activity logged yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(manager.activityLogs.enumerated()), id: \.element.id) { index, entry in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(logLevelColor(entry.level))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 5)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.userFriendlyMessage)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.primary)

                                    if !entry.technicalDetail.isEmpty {
                                        Text(entry.technicalDetail)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Text(entry.timestamp, style: .time)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            if index < manager.activityLogs.count - 1 {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    private func logLevelColor(_ level: ActivityLogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .action: return .green
        case .warning: return .orange
        }
    }

    // MARK: - Reusable Native System-Settings Building Blocks

    private func sectionGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func settingsGroupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func settingsToggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(disabled ? .secondary : .primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Readable Picker Names for System Settings

extension TimeoutPreset {
    fileprivate var fullName: String {
        switch self {
        case .fiveMinutes: return "5 Minutes"
        case .tenMinutes: return "10 Minutes"
        case .fifteenMinutes: return "15 Minutes"
        case .thirtyMinutes: return "30 Minutes"
        case .oneHour: return "1 Hour"
        }
    }
}

extension QuitTimeoutPreset {
    fileprivate var fullName: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .sixHours: return "6 Hours"
        case .twelveHours: return "12 Hours"
        case .oneDay: return "24 Hours"
        }
    }
}

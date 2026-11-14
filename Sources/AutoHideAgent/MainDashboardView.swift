import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Native macOS System Settings style Desktop Window (`MainDashboardView`).
/// - Left sidebar uses native `.listStyle(.sidebar)` navigation without cramped action buttons.
/// - Detail pane uses clean System-Settings grouped rows (`maxWidth: 660`) with switches and menus
///   instead of tiny checkboxes or cluttered custom badges.
@MainActor
public struct MainDashboardView: View {
    @Bindable var manager: AutoHideManager
    @ObservedObject private var updateController = UpdateController.shared

    @State private var customInput: String = ""
    @State private var selectedSection: NavigationSection = .overview
    @State private var appSearchText: String = ""
    @State private var logSearchText: String = ""
    @State private var isMaximized: Bool = false
    @State private var hoveredAppID: String? = nil
    @State private var hoveredExclusionItem: String? = nil
    @State private var hoveredLogID: UUID? = nil
    @State private var copiedHomebrewCommand: Bool = false
    @State private var isRefreshingApps: Bool = false

    public enum NavigationSection: String, CaseIterable, Identifiable {
        case overview = "General"
        case runningApps = "Background Apps"
        case exclusions = "Excluded Apps"
        case activityLog = "Activity Log"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .overview: return "gearshape.fill"
            case .runningApps: return "macwindow.on.rectangle"
            case .exclusions: return "shield.lefthalf.filled"
            case .activityLog: return "clock.arrow.circlepath"
            }
        }

        public var tintColor: Color {
            switch self {
            case .overview: return .blue
            case .runningApps: return .cyan
            case .exclusions: return .indigo
            case .activityLog: return .teal
            }
        }
    }

    @State private var isDashboardVisible = false

    @State private var isPrivacyInfoExpanded: Bool = false
    @State private var showPermissionGrantedBadge: Bool = false

    public init(manager: AutoHideManager) {
        self.manager = manager
    }

    public var body: some View {
        mainContent
            .animation(.easeInOut(duration: 0.25), value: manager.isAccessibilityTrusted)
            .onAppear { manager.refreshAccessibilityTrustStatus(promptIfNeeded: false) }
    }

    // MARK: - Modern Non-Blocking Accessibility Alert & Privacy Guarantee

    private var accessibilityAlertBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Accessibility Permission Required")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("Paused")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.15))
                            )
                    }

                    Text("AutoHideAgent is paused. macOS requires Accessibility access so background windows can be hidden and managed.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button {
                    manager.openSystemAccessibilityPrivacyPane()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                        Text("Open System Settings…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)
                .pointerStyle(.link)

                Button("Reset & Retry") {
                    manager.resetAndPromptAccessibilityPermission()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .pointerStyle(.link)
                .help("Clears stale macOS permission registrations from older builds and triggers a fresh prompt")

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPrivacyInfoExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPrivacyInfoExpanded ? "chevron.up" : "info.circle")
                        Text(isPrivacyInfoExpanded ? "Hide Details" : "Why is this needed?")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(TactileButtonStyle(pressedScale: 0.98, pressedOpacity: 0.78))
                .foregroundStyle(Color.accentColor)
                .pointingHandCursor()
            }

            if isPrivacyInfoExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text("Privacy & Security Guarantee:")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    privacyBullet(
                        icon: "macwindow.badge.plus",
                        title: "Window Hiding Only",
                        desc: "Uses Apple's AXUIElement API strictly to minimize or hide background application windows."
                    )
                    privacyBullet(
                        icon: "eye.slash.fill",
                        title: "Zero Screen Recording & Keystroke Access",
                        desc: "Never captures screenshots, video feeds, or keyboard inputs. Fully sandboxed from your private documents."
                    )
                    privacyBullet(
                        icon: "network.slash",
                        title: "100% Offline & Local",
                        desc: "Runs entirely on your Mac. Never connects to external servers and collects zero telemetry."
                    )
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Already switched ON in System Settings? Simply flip it OFF and back ON once to refresh.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func privacyBullet(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionGrantedSuccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text("Accessibility Permission Enabled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("AutoHideAgent is active and monitoring background windows.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarView
                .navigationSplitViewColumnWidth(min: 240, ideal: 255, max: 290)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailCanvas
                .toolbar(removing: .sidebarToggle)
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 840, idealWidth: 960, minHeight: 560, idealHeight: 620)
        .onAppear {
            updateDashboardVisibility()
            manager.refreshRunningApps()
            manager.refreshLaunchAtLoginStatus()
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
            if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == AppRuntime.dashboardWindowIdentifier }) {
                isMaximized = window.isZoomed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
            if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == AppRuntime.dashboardWindowIdentifier }) {
                isMaximized = window.isZoomed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !manager.isAccessibilityTrusted {
                manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
            }
        }
        .onChange(of: manager.isAccessibilityTrusted) { oldValue, newValue in
            if !oldValue && newValue {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showPermissionGrantedBadge = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showPermissionGrantedBadge = false
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue == AppRuntime.dashboardWindowIdentifier else { return }
            updateDashboardVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window.identifier?.rawValue == AppRuntime.dashboardWindowIdentifier {
                isDashboardVisible = false
            }
        }
        .task(id: isDashboardVisible && selectedSection == .runningApps) {
            guard isDashboardVisible, selectedSection == .runningApps else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation()
                    manager.requestRunningAppsRefresh()
                }
            } catch { /* Hiding the window or changing tabs cancels refresh work. */ }
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: NSNotification.Name("\(manager.isDevBuild ? "com.systems.autohideagent.dev" : "com.systems.autohideagent").debugSelectSection")
            )
        ) { notification in
            guard autoHideDebugHooksEnabled else { return }
            if let raw = notification.object as? String,
               let section = NavigationSection(rawValue: raw) {
                selectedSection = section
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .runningApps {
                DispatchQueue.main.async {
                    manager.refreshRunningApps()
                }
            }
        }
    }

    private func updateDashboardVisibility() {
        let window = NSApplication.shared.windows.first {
            $0.identifier?.rawValue == AppRuntime.dashboardWindowIdentifier
        }
        isDashboardVisible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
    }

    private func toggleMaximize() {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == AppRuntime.dashboardWindowIdentifier }) {
            window.performZoom(nil)
            isMaximized = window.isZoomed
        }
    }

    // MARK: - 1. Liquid Glass Sidebar

    private var sidebarView: some View {
        // Native sidebar List: Apple's own selection highlight (Liquid Glass on macOS 26+),
        // arrow-key navigation, and reliable click handling. Every row is a single tagged
        // value — never insert untagged children here or selection will desync.
        List(selection: $selectedSection) {
            ForEach(NavigationSection.allCases) { section in
                HStack(spacing: 9) {
                    LiquidGlassIcon(
                        systemName: section.icon,
                        tint: section.tintColor,
                        size: 24,
                        symbolSize: 12
                    )
                    Text(section.rawValue)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .padding(.vertical, 2)
                .badge(badgeCount(for: section))
                .tag(section)
                .pointingHandCursor()
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarStatusFooter
        }
    }

    private func badgeCount(for section: NavigationSection) -> Int {
        switch section {
        case .overview, .activityLog:
            return 0
        case .runningApps:
            return manager.runningRegularApps.count
        case .exclusions:
            return manager.whitelistedBundleIDs.count
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
        guard manager.isAccessibilityTrusted else { return .orange }
        guard manager.isEnabled else { return Color.secondary.opacity(0.45) }
        return manager.isTemporarilyPaused ? .orange : .green
    }

    private var statusSummaryText: String {
        guard manager.isAccessibilityTrusted else { return "Needs Permission • Paused" }
        guard manager.isEnabled else { return "AutoHideAgent is Off" }
        if let until = manager.pausedUntilDate, Date.now < until {
            return "Paused (\(manager.formatFriendlyDuration(until.timeIntervalSinceNow)))"
        }
        return "Active • \(manager.visibleBackgroundAppsCount) visible"
    }

    // MARK: - 2. Native macOS Detail Canvas (Adaptive Width)

    private var detailCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !manager.isAccessibilityTrusted {
                    accessibilityAlertBanner
                } else if showPermissionGrantedBadge {
                    permissionGrantedSuccessBanner
                }

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
            .frame(maxWidth: selectedSection == .overview ? 680 : .infinity, alignment: .leading)
            .padding(.horizontal, selectedSection == .overview ? 28 : 22)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: selectedSection == .overview ? .center : .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Fresh scroll view per tab so switching tabs always starts at the top
        // instead of inheriting a scroll offset from a longer tab.
        .id(selectedSection)
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
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(manager.isDevBuild ? "AutoHideAgent Dev" : "AutoHideAgent")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)

                                if manager.isDryRunMode {
                                    Text("DRY RUN")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                                }
                            }

                            Text(masterHeroSubtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $manager.isEnabled)
                            .toggleStyle(.switch)
                            .pointerStyle(.link)
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
                            if manager.isTemporarilyPaused {
                                Button {
                                    manager.resumeFromTemporaryPause()
                                } label: {
                                    Label("Resume", systemImage: "play.fill")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .pointerStyle(.link)
                                .controlSize(.regular)
                            }

                            Menu {
                                ForEach(PausePreset.allCases) { preset in
                                    Button {
                                        manager.pauseDurationSeconds = preset.rawValue
                                        manager.pause(for: TimeInterval(preset.rawValue))
                                    } label: {
                                        HStack {
                                            Text("Pause for \(preset.descriptiveLabel)")
                                            if manager.pauseDurationSeconds == preset.rawValue {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }

                                if manager.isTemporarilyPaused {
                                    Divider()
                                    Button {
                                        manager.resumeFromTemporaryPause()
                                    } label: {
                                        Label("Resume Timers Now", systemImage: "play.fill")
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: manager.isTemporarilyPaused ? "cup.and.saucer.fill" : "pause.circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(manager.isTemporarilyPaused ? Color.orange : Color.secondary)
                                    Text(manager.isTemporarilyPaused ? "Paused (\(manager.formatFriendlyDuration(manager.pausedUntilDate?.timeIntervalSinceNow ?? 0)))" : "Pause Timers…")
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .menuStyle(.borderedButton)
                            .pointerStyle(.link)
                            .controlSize(.regular)
                            .disabled(!manager.isEnabled)

                            Button {
                                manager.hideAllBackgroundAppsNow()
                            } label: {
                                Label(
                                    manager.eligibleToHideCount > 0
                                        ? "Hide \(manager.eligibleToHideCount) \(manager.eligibleToHideCount == 1 ? "App" : "Apps") Now"
                                    : "Hide Others Now",
                                    systemImage: "eye.slash.fill"
                                )
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .pointingHandCursor()
                            .disabled(!manager.isEnabled || manager.eligibleToHideCount == 0)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }

            // Accessibility Permission Card — only when granted; when missing, the
            // top-of-page banner already covers it (avoids two duplicate warnings).
            if manager.isAccessibilityTrusted {
                accessibilityStatusGroup
            }

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
                            .pointingHandCursor()
                            .disabled(!manager.isEnabled || !manager.isAutoHideEnabled)

                            Toggle("", isOn: $manager.isAutoHideEnabled)
                                .toggleStyle(.switch)
                                .pointerStyle(.link)
                                .labelsHidden()
                                .disabled(!manager.isEnabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.horizontal, 14)

                        // Row 2: Alert When Apps Are Hidden
                        settingsToggleRow(
                            title: "Alert When Apps Are Hidden",
                            subtitle: "Send a system notification whenever an inactive background app is automatically hidden.",
                            isOn: $manager.alertOnAppHide,
                            disabled: !manager.isEnabled || !manager.isAutoHideEnabled
                        )

                        Divider().padding(.horizontal, 14)

                        // Row 3: Auto-Quit
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
                            .pointingHandCursor()
                            .disabled(!manager.isEnabled || !manager.isAutoQuitEnabled)

                            Toggle("", isOn: $manager.isAutoQuitEnabled)
                                .toggleStyle(.switch)
                                .pointerStyle(.link)
                                .labelsHidden()
                                .disabled(!manager.isEnabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.horizontal, 14)

                        // Row 4: Ask Confirmation Before Quitting
                        settingsToggleRow(
                            title: "Ask Confirmation Before Auto-Quitting",
                            subtitle: "Show a confirmation dialog before quitting an inactive app so you never lose work.",
                            isOn: $manager.confirmBeforeAutoQuit,
                            disabled: !manager.isEnabled || !manager.isAutoQuitEnabled
                        )

                        Divider().padding(.horizontal, 14)

                        // Row 5: Alert When Apps Are Quit
                        settingsToggleRow(
                            title: "Alert When Apps Are Quit",
                            subtitle: "Send a system notification whenever an inactive background app is automatically quit.",
                            isOn: $manager.alertOnAppQuit,
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
                            title: "Show AutoHideAgent in Menu Bar",
                            subtitle: "Display the quick Control Center panel icon in your top macOS menu bar.",
                            isOn: $manager.showInMenuBar
                        )

                        Divider().padding(.horizontal, 14)

                        settingsToggleRow(
                            title: "Show AutoHideAgent in Dock",
                            subtitle: "Keep AutoHideAgent visible in the macOS Dock and Command-Tab app switcher.",
                            isOn: $manager.showInDock
                        )

                        Divider().padding(.horizontal, 14)

                        settingsToggleRow(
                            title: "Launch AutoHideAgent at Login",
                            subtitle: "Start automatically in the background when you sign in to your Mac.",
                            isOn: Binding(
                                get: { manager.launchAtLoginEnabled },
                                set: { manager.setLaunchAtLogin($0) }
                            )
                        )
                    }
                }
            }

            // Software Updates & Homebrew Cask Group
            VStack(alignment: .leading, spacing: 6) {
                sectionGroupTitle("Software Updates & Distribution")

                settingsGroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        // Sparkle In-App Auto-Updates Toggle
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatically Check for Updates")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Checks for new releases in the background using Sparkle.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("", isOn: $updateController.automaticallyChecksForUpdates)
                                .toggleStyle(.switch)
                                .pointerStyle(.link)
                                .labelsHidden()
                                .disabled(!updateController.isUpdaterAvailable)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.horizontal, 14)

                        // Manual Check Button + Version & Status
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current Version: \(currentAppVersionDisplay)")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Last checked: \(updateController.friendlyLastCheckDate)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                updateController.checkForUpdates()
                            } label: {
                                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .pointerStyle(.link)
                            .controlSize(.regular)
                            .disabled(!updateController.canCheckForUpdates)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.horizontal, 14)

                        // Homebrew Cask Support Row
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Homebrew Cask Support")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("CLI")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                }
                                Text("Install or upgrade via terminal: brew install --cask msynthnova/tap/autohideagent")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString("brew install --cask msynthnova/tap/autohideagent", forType: .string)
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    copiedHomebrewCommand = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        copiedHomebrewCommand = false
                                    }
                                }
                            } label: {
                                Label(
                                    copiedHomebrewCommand ? "Copied to Clipboard" : "Copy Command",
                                    systemImage: copiedHomebrewCommand ? "checkmark" : "doc.on.doc"
                                )
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(copiedHomebrewCommand ? Color.green : Color.primary)
                            }
                            .buttonStyle(.bordered)
                            .pointerStyle(.link)
                            .controlSize(.regular)
                            .help("Copy Homebrew installation command to clipboard")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
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

    private var currentAppVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.8"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "15"
        return "v\(version) (Build \(build))"
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
                            ? "macOS allows AutoHideAgent to hide background applications automatically."
                            : "Click \"Grant Access\" and enable AutoHideAgent in System Settings → Privacy & Security → Accessibility."
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
                        .pointerStyle(.link)
                        .controlSize(.regular)
                        .help("Clears stale macOS permission cache from older builds and prompts freshly")

                        Button("Grant Access…") {
                            manager.refreshAccessibilityTrustStatus(promptIfNeeded: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .pointerStyle(.link)
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Apps")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(manager.visibleBackgroundAppsCount) visible • \(manager.hiddenBackgroundAppsCount) hidden")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 16)

                TextField("Filter apps…", text: $appSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)

                Button {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        isRefreshingApps = true
                    }
                    manager.refreshRunningApps()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isRefreshingApps = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshingApps ? 360 : 0))
                        .animation(.easeInOut(duration: 0.35), value: isRefreshingApps)
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .help("Refresh the list now (also refreshes automatically every 10 seconds)")

                Button {
                    manager.hideAllBackgroundAppsNow()
                } label: {
                    Label(
                        manager.eligibleToHideCount > 0
                            ? "Hide \(manager.eligibleToHideCount) Visible"
                            : "Hide All Visible",
                        systemImage: "eye.slash.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()
                .disabled(manager.eligibleToHideCount == 0)
                .fixedSize()
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
        let isWhitelisted = app.isWhitelisted
        let isHovered = hoveredAppID == app.id

        return HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 1.5, x: 0, y: 1)
                    .opacity(app.isHidden ? 0.6 : 1.0)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "app.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 7) {
                    Text(app.localizedName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(app.isHidden ? .secondary : .primary)

                    appStatusBadge(for: app, isWhitelisted: isWhitelisted)
                }

                Text(appStatusDescription(for: app, isWhitelisted: isWhitelisted))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button(isWhitelisted ? "Excluded" : "Exclude") {
                    if isWhitelisted {
                        manager.removeWhitelistEntry(app.bundleIdentifier)
                    } else {
                        manager.addWhitelistEntry(app.bundleIdentifier)
                    }
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .tint(isWhitelisted ? .indigo : .none)
                .controlSize(.small)

                if !app.isHidden {
                    Button("Hide") {
                        manager.manuallyHideApp(app)
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                    .controlSize(.small)
                }

                Button("Quit") {
                    manager.manuallyQuitApp(app)
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.045) : Color.clear)
        )
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredAppID = hovering ? app.id : (hoveredAppID == app.id ? nil : hoveredAppID)
        }
    }

    @ViewBuilder
    private func appStatusBadge(for app: RunningAppInfo, isWhitelisted: Bool) -> some View {
        if isWhitelisted {
            Text("Excluded")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.purple.opacity(0.12)))
        } else if app.hasActivePowerAssertion {
            Text("Audio / Call")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
        } else if app.isProtectedMostRecent {
            Text("Recent Background")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
        } else if app.isHidden {
            Text("Hidden")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
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

                Button("Add") {
                    addCustomExclusion()
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    chooseAppToExclude()
                } label: {
                    Label("Choose App…", systemImage: "plus.app")
                }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()
                .fixedSize()
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
                            let resolved = resolveApp(item)
                            let isHovered = hoveredExclusionItem == item

                            HStack(spacing: 12) {
                                if let icon = resolved.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(resolved.name)
                                        .font(.system(size: 13, weight: .medium))
                                    if resolved.name != item {
                                        Text(item)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if item.lowercased() != "com.apple.finder" {
                                    Button("Remove") {
                                        manager.removeWhitelistEntry(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .pointingHandCursor()
                                    .controlSize(.small)
                                } else {
                                    Text("System Default")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isHovered ? Color.primary.opacity(0.045) : Color.clear)
                            )
                            .padding(.horizontal, 4)
                            .animation(.easeInOut(duration: 0.12), value: isHovered)
                            .onHover { hovering in
                                hoveredExclusionItem = hovering ? item : (hoveredExclusionItem == item ? nil : hoveredExclusionItem)
                            }

                            if index < manager.whitelistedBundleIDs.count - 1 {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Resolves a stored exclusion (bundle ID or app name) to a display name + icon.
    private func resolveApp(_ identifier: String) -> (name: String, icon: NSImage?) {
        if let running = manager.runningRegularApps.first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.localizedName.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return (running.localizedName, running.icon)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (identifier, nil)
    }

    private func chooseAppToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps to Exclude"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let identifier = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
            manager.addWhitelistEntry(identifier)
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
                .pointingHandCursor()
                .controlSize(.small)

                Button("Reveal in Finder") {
                    manager.revealDiagnosticLogInFinder()
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .controlSize(.small)

                Button("Clear") {
                    manager.clearLogs()
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
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
                            let isHovered = hoveredLogID == entry.id

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
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
                            )
                            .padding(.horizontal, 4)
                            .animation(.easeInOut(duration: 0.12), value: isHovered)
                            .onHover { hovering in
                                hoveredLogID = hovering ? entry.id : (hoveredLogID == entry.id ? nil : hoveredLogID)
                            }

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
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
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
                .pointerStyle(.link)
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

// MARK: - Liquid Glass Icon Component

/// Sidebar icon tile. On macOS 26+ it uses Apple's real Liquid Glass material
/// (`glassEffect`) tinted with the section color — the same material the system
/// uses for toolbars and Safari's controls. Older systems get a matching
/// gradient tile so the look stays consistent.
public struct LiquidGlassIcon: View {
    public let systemName: String
    public let tint: Color
    public var size: CGFloat = 24
    public var symbolSize: CGFloat = 12

    public init(systemName: String, tint: Color, size: CGFloat = 24, symbolSize: CGFloat = 12) {
        self.systemName = systemName
        self.tint = tint
        self.size = size
        self.symbolSize = symbolSize
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
    }

    private var glyph: some View {
        Image(systemName: systemName)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
    }

    public var body: some View {
        // Solid tint lives in the content layer so it stays colored even when the
        // window is inactive; the glass layer adds Apple's specular rim + refraction.
        let tile = glyph.background(shape.fill(tint.gradient))
        if #available(macOS 26.0, *) {
            tile.glassEffect(.regular, in: shape)
        } else {
            tile.overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        }
    }
}

// MARK: - Pointing Hand Cursor Extension

extension View {
    /// Applies macOS pointing hand cursor on hover for clickable items.
    @ViewBuilder
    public func pointingHandCursor() -> some View {
        self.pointerStyle(.link)
    }
}

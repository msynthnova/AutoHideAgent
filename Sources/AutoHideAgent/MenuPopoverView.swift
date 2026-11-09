import AppKit
import Combine
import SwiftUI

/// Clean, quick-action Menu Bar Popover (`width: 320`).
/// Designed specifically for fast menu-bar interactions without overflowing vertically or glitching.
@MainActor
public struct MenuPopoverView: View {
    @Bindable var manager: AutoHideManager
    public var onOpenMainWindow: (() -> Void)?

    private let uiRefreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    public init(manager: AutoHideManager, onOpenMainWindow: (() -> Void)? = nil) {
        self.manager = manager
        self.onOpenMainWindow = onOpenMainWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if !manager.isAccessibilityTrusted {
                accessibilityBanner
            }

            quickActionsRow

            Divider()

            timersQuickControlSection

            Divider()

            runningAppsMiniSection

            Divider()

            footerSection
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            manager.refreshRunningApps()
            manager.refreshLaunchAtLoginStatus()
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
        }
        .onReceive(uiRefreshTimer) { _ in
            manager.refreshRunningApps()
        }
    }

    // MARK: - 1. Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            if let appIcon = NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .opacity(manager.isEnabled && !manager.isTemporarilyPaused ? 1.0 : 0.55)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("AutoHide")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Text(statusSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $manager.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
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
            return "Snoozed (\(remaining) left)"
        }
        return "Active — Watching Apps"
    }

    // MARK: - 2. Accessibility Banner (Only if needed)

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))

            Text("Accessibility needed to hide apps")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Button("Grant") {
                manager.refreshAccessibilityTrustStatus(promptIfNeeded: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.mini)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
    }

    // MARK: - 3. Quick Actions

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            Button {
                manager.hideAllBackgroundAppsNow()
            } label: {
                Label("Hide Others Now", systemImage: "eye.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button {
                manager.togglePauseForOneHour()
            } label: {
                Label(
                    manager.isTemporarilyPaused ? "Resume" : "Pause 1h",
                    systemImage: manager.isTemporarilyPaused ? "play.fill" : "cup.and.saucer.fill"
                )
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!manager.isEnabled)
        }
    }

    // MARK: - 4. Compact Timers Control

    private var timersQuickControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Auto-Hide Row
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Auto-Hide After", systemImage: "timer")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(manager.isAutoHideEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $manager.isAutoHideEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!manager.isEnabled)
                }

                Picker("", selection: $manager.timeoutSeconds) {
                    ForEach(TimeoutPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!manager.isEnabled || !manager.isAutoHideEnabled)
            }

            // Auto-Quit Row
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Auto-Quit After", systemImage: "xmark.octagon.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(manager.isAutoQuitEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $manager.isAutoQuitEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!manager.isEnabled)
                }

                Picker("", selection: $manager.quitTimeoutSeconds) {
                    ForEach(QuitTimeoutPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!manager.isEnabled || !manager.isAutoQuitEnabled)
            }
        }
    }

    // MARK: - 5. Compact Running Apps List

    private var runningAppsMiniSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Background Apps (\(manager.runningRegularApps.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let latestLog = manager.activityLogs.first {
                    Text(latestLog.userFriendlyMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 155, alignment: .trailing)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if manager.runningRegularApps.isEmpty {
                        Text("No background apps open.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(manager.runningRegularApps) { app in
                            miniAppRow(for: app)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func miniAppRow(for app: RunningAppInfo) -> some View {
        let isWhitelisted = manager.whitelistedBundleIDs.contains {
            $0.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame ||
            $0.caseInsensitiveCompare(app.localizedName) == .orderedSame
        }

        return HStack(spacing: 7) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 13))
                    .frame(width: 18, height: 18)
            }

            Text(app.localizedName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(isWhitelisted ? "Excluded" : countdownLabel(for: app))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isWhitelisted ? .secondary : (app.isHidden ? .secondary : .primary))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))

            Button {
                if isWhitelisted {
                    manager.removeWhitelistEntry(app.bundleIdentifier)
                } else {
                    manager.addWhitelistEntry(app.bundleIdentifier)
                }
            } label: {
                Image(systemName: isWhitelisted ? "shield.slash.fill" : "shield")
                    .font(.system(size: 11))
                    .foregroundStyle(isWhitelisted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isWhitelisted ? "Remove from Exclusions" : "Exclude \(app.localizedName)")

            if !app.isHidden {
                Button {
                    manager.manuallyHideApp(app)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide \(app.localizedName) now")
            }

            Button {
                manager.manuallyQuitApp(app)
            } label: {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Quit \(app.localizedName) now")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func countdownLabel(for app: RunningAppInfo) -> String {
        if app.hasActivePowerAssertion {
            return "Media/Call"
        }
        if app.isProtectedMostRecent {
            return "Recent"
        }
        guard let elapsed = app.elapsedInactiveSeconds else {
            return "Active"
        }
        if app.isHidden {
            if manager.isAutoQuitEnabled {
                let remQuit = max(0, TimeInterval(manager.quitTimeoutSeconds) - elapsed)
                return remQuit > 0 ? "Q: \(manager.formatFriendlyDuration(remQuit))" : "Hidden"
            }
            return "Hidden"
        }
        if !manager.isAutoHideEnabled {
            return "Visible"
        }
        let remHide = max(0, TimeInterval(manager.timeoutSeconds) - elapsed)
        return remHide > 0 ? manager.formatFriendlyDuration(remHide) : "Soon"
    }

    // MARK: - 6. Footer

    private var footerSection: some View {
        HStack(spacing: 8) {
            if let onOpenMainWindow {
                Button {
                    onOpenMainWindow()
                } label: {
                    Label("Open Full App", systemImage: "macwindow")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                manager.openDiagnosticLogFile()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open Diagnostic Log File")

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

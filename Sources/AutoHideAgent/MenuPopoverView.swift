import AppKit
import SwiftUI

/// Native AppKit `NSVisualEffectView` wrapper configured to match Apple's macOS Control Center
/// (`Sound` / `Wi-Fi` panel) translucency without bright background color bleed-through.
private struct ControlCenterVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

/// Native macOS Control Center ("Sound" menu style) floating panel view.
/// - Zero background polling timers (event-driven via `@Observable` `AutoHideManager`).
/// - Reports its exact measured height via `.onGeometryChange` so the floating `NSPanel`
///   never clips or miscalculates height when opening or expanding sub-sections.
@MainActor
public struct MenuPopoverView: View {
    @Bindable var manager: AutoHideManager
    public var onOpenMainWindow: (() -> Void)?
    public var onClosePanel: (() -> Void)?
    public var onHeightChange: ((CGFloat) -> Void)?

    @State private var expandedSection: ExpandableMenuSection? = nil
    @State private var hoveredRowID: String? = nil

    private enum ExpandableMenuSection: Equatable {
        case autoHide
        case autoQuit
    }

    public init(
        manager: AutoHideManager,
        onOpenMainWindow: (() -> Void)? = nil,
        onClosePanel: (() -> Void)? = nil,
        onHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.manager = manager
        self.onOpenMainWindow = onOpenMainWindow
        self.onClosePanel = onClosePanel
        self.onHeightChange = onHeightChange
    }

    public var body: some View {
        Group {
            if manager.isAccessibilityTrusted {
                fullPanelContent
            } else {
                setupRequiredPanel
            }
        }
        .frame(width: 308)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                ControlCenterVisualEffectBackground()
                Color(nsColor: .windowBackgroundColor).opacity(0.32)
            }
        )
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if h > 50 { onHeightChange?(h) }
        }
    }

    private var setupRequiredPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text("Setup Required")
                .font(.system(size: 14, weight: .semibold))
            Text("Grant Accessibility access to start using AutoHide.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open AutoHide to Set Up") {
                onClosePanel?()
                onOpenMainWindow?()
            }
            .buttonStyle(.borderedProminent)
            .pointerStyle(.link)
            Button("Quit AutoHide") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private var fullPanelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Header ("AutoHide" + Master Switch)
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            hairlineDivider

            // 2. Automation Modes (Control Center Circular Icon Rows + Expandable Sub-Menus)
            sectionHeader("Automation")
                .padding(.top, 8)
                .padding(.bottom, 4)

            autoHideControlCenterRow
            if expandedSection == .autoHide {
                autoHideExpandedSubmenu
            }

            autoQuitControlCenterRow
            if expandedSection == .autoQuit {
                autoQuitExpandedSubmenu
            }

            snoozeControlCenterRow
                .padding(.bottom, 6)

            hairlineDivider

            // 3. Quick Actions (Clean — no permission prompt clutter)
            sectionHeader("Quick Actions")
                .padding(.top, 8)
                .padding(.bottom, 4)

            hideNowActionRow
                .padding(.bottom, 6)

            hairlineDivider

            // 4. Footer Menu Links (Matches "Sound Settings..." in macOS Control Center)
            VStack(alignment: .leading, spacing: 2) {
                footerMenuLinkRow(
                    id: "footer.openWindow",
                    title: "AutoHide Settings…",
                    shortcutHint: "⌘0"
                ) {
                    onClosePanel?()
                    onOpenMainWindow?()
                }

                footerMenuLinkRow(
                    id: "footer.openLog",
                    title: "Open Diagnostic Log…"
                ) {
                    onClosePanel?()
                    manager.openDiagnosticLogFile()
                }

                footerMenuLinkRow(
                    id: "footer.quit",
                    title: "Quit AutoHide",
                    shortcutHint: "⌘Q"
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: NSNotification.Name("com.example.AutoHideAgent.debugSetExpandedSection")
            )
        ) { notification in
            if let mode = notification.object as? String {
                switch mode {
                case "autoHide": expandedSection = .autoHide
                case "autoQuit": expandedSection = .autoQuit
                default: expandedSection = nil
                }
            }
        }
    }

    // MARK: - 1. Control Center Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AutoHide")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6.5, height: 6.5)
                    Text(statusSubtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $manager.isEnabled)
                .toggleStyle(.switch)
                .pointerStyle(.link)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private var statusDotColor: Color {
        guard manager.isEnabled else { return Color.secondary.opacity(0.45) }
        return manager.isTemporarilyPaused ? .orange : .green
    }

    private var statusSubtitle: String {
        guard manager.isEnabled else { return "Off" }
        if let until = manager.pausedUntilDate, Date.now < until {
            let remaining = manager.formatFriendlyDuration(until.timeIntervalSinceNow)
            return "Paused (\(remaining) left)"
        }
        return "Active"
    }

    // MARK: - 2. Expandable Control Center Rows (Like AirPods Pro -> Listening Mode)

    private var autoHideControlCenterRow: some View {
        let isActive = manager.isEnabled && manager.isAutoHideEnabled
        let currentLabel = TimeoutPreset(rawValue: manager.timeoutSeconds)?.label ?? "\(manager.timeoutSeconds / 60)m"
        let isExpanded = (expandedSection == .autoHide)

        return controlCenterItemRow(
            id: "row.autoHide",
            icon: "eye.slash.fill",
            isActive: isActive,
            activeTint: .accentColor,
            title: "Auto-Hide Apps",
            subtitle: isActive ? "After \(currentLabel) of inactivity" : "Off",
            showsChevron: true,
            isExpanded: isExpanded,
            onIconTap: {
                if !manager.isEnabled { manager.isEnabled = true }
                manager.isAutoHideEnabled.toggle()
            },
            onRowTap: {
                expandedSection = isExpanded ? nil : .autoHide
            }
        )
    }

    private var autoHideExpandedSubmenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Hide Inactive Apps After")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(TimeoutPreset.allCases) { preset in
                let isSelected = manager.isAutoHideEnabled && (manager.timeoutSeconds == preset.rawValue)
                submenuCheckmarkRow(
                    id: "autohide.\(preset.rawValue)",
                    title: preset.descriptiveLabel,
                    icon: "timer",
                    isSelected: isSelected
                ) {
                    manager.isEnabled = true
                    manager.isAutoHideEnabled = true
                    manager.timeoutSeconds = preset.rawValue
                }
            }

            submenuCheckmarkRow(
                id: "autohide.off",
                title: "Off",
                icon: "eye",
                isSelected: !manager.isAutoHideEnabled
            ) {
                manager.isAutoHideEnabled = false
            }
            .padding(.bottom, 6)
        }
        .background(Color.primary.opacity(0.06))
        .overlay(alignment: .top) { hairlineDivider }
        .overlay(alignment: .bottom) { hairlineDivider }
    }

    private var autoQuitControlCenterRow: some View {
        let isActive = manager.isEnabled && manager.isAutoQuitEnabled
        let currentLabel = QuitTimeoutPreset(rawValue: manager.quitTimeoutSeconds)?.label ?? "\(manager.quitTimeoutSeconds / 3600)h"
        let isExpanded = (expandedSection == .autoQuit)

        return controlCenterItemRow(
            id: "row.autoQuit",
            icon: "power",
            isActive: isActive,
            activeTint: .accentColor,
            title: "Auto-Quit Hidden Apps",
            subtitle: isActive
                ? "After \(currentLabel) • \(manager.confirmBeforeAutoQuit ? "Ask first" : "Automatic")"
                : "Off",
            showsChevron: true,
            isExpanded: isExpanded,
            onIconTap: {
                if !manager.isEnabled { manager.isEnabled = true }
                manager.isAutoQuitEnabled.toggle()
            },
            onRowTap: {
                expandedSection = isExpanded ? nil : .autoQuit
            }
        )
    }

    private var autoQuitExpandedSubmenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Quit Hidden Apps After")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(QuitTimeoutPreset.allCases) { preset in
                let isSelected = manager.isAutoQuitEnabled && (manager.quitTimeoutSeconds == preset.rawValue)
                submenuCheckmarkRow(
                    id: "autoquit.\(preset.rawValue)",
                    title: preset.descriptiveLabel,
                    icon: "clock.badge.xmark",
                    isSelected: isSelected
                ) {
                    manager.isEnabled = true
                    manager.isAutoQuitEnabled = true
                    manager.quitTimeoutSeconds = preset.rawValue
                }
            }

            submenuCheckmarkRow(
                id: "autoquit.off",
                title: "Off",
                icon: "xmark.circle",
                isSelected: !manager.isAutoQuitEnabled
            ) {
                manager.isAutoQuitEnabled = false
            }

            hairlineDivider
                .padding(.vertical, 4)

            submenuCheckmarkRow(
                id: "autoquit.confirm",
                title: "Ask Confirmation Before Quitting",
                icon: "checkmark.shield",
                isSelected: manager.confirmBeforeAutoQuit
            ) {
                manager.confirmBeforeAutoQuit.toggle()
            }
            .padding(.bottom, 6)
        }
        .background(Color.primary.opacity(0.06))
        .overlay(alignment: .top) { hairlineDivider }
        .overlay(alignment: .bottom) { hairlineDivider }
    }

    private var snoozeControlCenterRow: some View {
        let isSnoozed = manager.isTemporarilyPaused
        return controlCenterItemRow(
            id: "row.snooze",
            icon: "cup.and.saucer.fill",
            isActive: isSnoozed,
            activeTint: .orange,
            title: isSnoozed ? "Snoozed for 1 Hour" : "Pause for 1 Hour",
            subtitle: isSnoozed ? "Click to resume timers now" : "Temporarily freeze all timers",
            showsChevron: false,
            isExpanded: false,
            onIconTap: {
                manager.togglePauseForOneHour()
            },
            onRowTap: {
                manager.togglePauseForOneHour()
            }
        )
    }

    // MARK: - 3. Quick Actions Row

    private var hideNowActionRow: some View {
        let visibleCount = manager.visibleBackgroundAppsCount
        let subtitleText = visibleCount > 0
            ? "Hide \(visibleCount) visible background \(visibleCount == 1 ? "app" : "apps") right now"
            : "All background apps are already hidden"

        return controlCenterItemRow(
            id: "row.hideNow",
            icon: "eye.slash.circle.fill",
            isActive: visibleCount > 0,
            activeTint: .accentColor,
            title: "Hide Other Open Apps Now",
            subtitle: subtitleText,
            showsChevron: false,
            isExpanded: false,
            onIconTap: {
                onClosePanel?()
                manager.hideAllBackgroundAppsNow()
            },
            onRowTap: {
                onClosePanel?()
                manager.hideAllBackgroundAppsNow()
            }
        )
    }

    // MARK: - Shared Control Center Components

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.11))
            .frame(height: 0.75)
            .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func controlCenterItemRow(
        id: String,
        icon: String,
        isActive: Bool,
        activeTint: Color,
        title: String,
        subtitle: String,
        showsChevron: Bool,
        isExpanded: Bool,
        onIconTap: @escaping () -> Void,
        onRowTap: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredRowID == id)

        HStack(spacing: 10) {
            // Circular Status Badge (tappable directly to toggle on/off like Wi-Fi / Bluetooth / AirPods)
            Button(action: onIconTap) {
                ZStack {
                    Circle()
                        .fill(isActive ? activeTint : Color.primary.opacity(0.11))
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            // Main Row Area (toggles action or expands submenu)
            Button(action: onRowTap) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.085) : Color.clear)
        )
        .padding(.horizontal, 6)
        .onHover { hovering in
            hoveredRowID = hovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
    }

    @ViewBuilder
    private func submenuCheckmarkRow(
        id: String,
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredRowID == id)

        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .opacity(isSelected ? 1.0 : 0.0)
                    .frame(width: 14, alignment: .center)

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering in
            hoveredRowID = hovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
    }

    @ViewBuilder
    private func footerMenuLinkRow(
        id: String,
        title: String,
        shortcutHint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredRowID == id)

        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer()

                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering in
            hoveredRowID = hovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
    }
}

// MARK: - Descriptive Labels for Control Center Sub-Menus

extension TimeoutPreset {
    fileprivate var descriptiveLabel: String {
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
    fileprivate var descriptiveLabel: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .sixHours: return "6 Hours"
        case .twelveHours: return "12 Hours"
        case .oneDay: return "24 Hours (1 Day)"
        }
    }
}

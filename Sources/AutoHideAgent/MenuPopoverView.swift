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

    @State private var hoveredRowID: String? = nil

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
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if manager.isAccessibilityTrusted {
                    fullPanelContent
                } else {
                    setupRequiredPanel
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                if h > 50 { onHeightChange?(h) }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 308, alignment: .topLeading)
        .background(
            ZStack {
                ControlCenterVisualEffectBackground()
                Color(nsColor: .windowBackgroundColor).opacity(0.32)
            }
        )
        .ignoresSafeArea()
    }

    private var setupRequiredPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .padding(.top, 4)

            Text("Accessibility Required")
                .font(.system(size: 14, weight: .bold))
                .multilineTextAlignment(.center)

            Text("AutoHideAgent is paused. macOS requires Accessibility access to automatically hide background windows.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                Button {
                    manager.openSystemAccessibilityPrivacyPane()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                        Text("Open System Settings…")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)
                .pointerStyle(.link)

                Button {
                    onClosePanel?()
                    onOpenMainWindow?()
                } label: {
                    Text("Open Full Dashboard")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerStyle(.link)
            }
            .padding(.top, 2)

            VStack(spacing: 4) {
                Text("💡 If already ON, toggle OFF and ON once.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Text("100% Offline • Zero Screen or Keystroke Access")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 2)

            hairlineDivider
                .padding(.vertical, 4)

            Button("Quit AutoHideAgent") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear {
            manager.refreshAccessibilityTrustStatus(promptIfNeeded: false)
        }
    }

    private var fullPanelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Header ("AutoHideAgent" + Master Switch)
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            hairlineDivider

            // 2. Automation Modes (Always-Visible Selector Lists)
            sectionHeader("Automation")
                .padding(.top, 8)
                .padding(.bottom, 4)

            autoHideSectionBlock

            autoQuitSectionBlock

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
                    title: "AutoHideAgent Settings…",
                    shortcutHint: "⌘0"
                ) {
                    onClosePanel?()
                    onOpenMainWindow?()
                }

                footerMenuLinkRow(
                    id: "footer.checkUpdates",
                    title: "Check for Updates…"
                ) {
                    onClosePanel?()
                    UpdateController.shared.checkForUpdates()
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
                    title: "Quit AutoHideAgent",
                    shortcutHint: "⌘Q"
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 1. Control Center Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(manager.isDevBuild ? "AutoHideAgent Dev" : "AutoHideAgent")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    if manager.isDryRunMode {
                        Text("DRY RUN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                    }
                }

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

    // MARK: - 2. Always-Visible Control Center Blocks (No Accordion)

    private var autoHideSectionBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            controlCenterHeaderToggleRow(
                id: "header.autoHide",
                icon: "eye.slash.fill",
                isActive: manager.isEnabled && manager.isAutoHideEnabled,
                activeTint: .accentColor,
                title: "Auto-Hide Apps",
                subtitle: (manager.isEnabled && manager.isAutoHideEnabled) ? "Hide inactive apps after:" : "Disabled",
                isOn: Binding(
                    get: { manager.isEnabled && manager.isAutoHideEnabled },
                    set: { newValue in
                        if !manager.isEnabled && newValue { manager.isEnabled = true }
                        manager.isAutoHideEnabled = newValue
                    }
                ),
                onIconTap: {
                    if !manager.isEnabled { manager.isEnabled = true }
                    manager.isAutoHideEnabled.toggle()
                }
            )

            autoHideSubmenuList
        }
    }

    private var autoHideSubmenuList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(TimeoutPreset.allCases) { preset in
                let isSelected = manager.isAutoHideEnabled && (manager.timeoutSeconds == preset.rawValue)
                submenuCheckmarkRow(
                    id: "autohide.\(preset.rawValue)",
                    title: preset.descriptiveLabel,
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
                isSelected: !manager.isAutoHideEnabled
            ) {
                manager.isAutoHideEnabled = false
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)

            alertWhenHiddenCheckboxRow
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var alertWhenHiddenCheckboxRow: some View {
        let isHovered = (hoveredRowID == "autohide.alert")

        return Button {
            manager.alertOnAppHide.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: manager.alertOnAppHide ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(manager.alertOnAppHide ? Color.accentColor : Color.secondary)
                    .frame(width: 14, alignment: .center)

                Text("Alert When Apps Hide")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(TactileButtonStyle(pressedScale: 0.985, pressedOpacity: 0.78))
        .pointerStyle(.link)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredRowID = hovering ? "autohide.alert" : (hoveredRowID == "autohide.alert" ? nil : hoveredRowID)
        }
    }

    private var autoQuitSectionBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            controlCenterHeaderToggleRow(
                id: "header.autoQuit",
                icon: "power",
                isActive: manager.isEnabled && manager.isAutoQuitEnabled,
                activeTint: .accentColor,
                title: "Auto-Quit Hidden Apps",
                subtitle: (manager.isEnabled && manager.isAutoQuitEnabled) ? "Quit hidden apps after:" : "Disabled",
                isOn: Binding(
                    get: { manager.isEnabled && manager.isAutoQuitEnabled },
                    set: { newValue in
                        if !manager.isEnabled && newValue { manager.isEnabled = true }
                        manager.isAutoQuitEnabled = newValue
                    }
                ),
                onIconTap: {
                    if !manager.isEnabled { manager.isEnabled = true }
                    manager.isAutoQuitEnabled.toggle()
                }
            )

            autoQuitSubmenuList
        }
    }

    private var autoQuitSubmenuList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(QuitTimeoutPreset.allCases) { preset in
                let isSelected = manager.isAutoQuitEnabled && (manager.quitTimeoutSeconds == preset.rawValue)
                submenuCheckmarkRow(
                    id: "autoquit.\(preset.rawValue)",
                    title: preset.descriptiveLabel,
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
                isSelected: !manager.isAutoQuitEnabled
            ) {
                manager.isAutoQuitEnabled = false
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)

            confirmationCheckboxRow

            alertWhenQuitCheckboxRow
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var confirmationCheckboxRow: some View {
        let isHovered = (hoveredRowID == "autoquit.confirm")

        return Button {
            manager.confirmBeforeAutoQuit.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: manager.confirmBeforeAutoQuit ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(manager.confirmBeforeAutoQuit ? Color.accentColor : Color.secondary)
                    .frame(width: 14, alignment: .center)

                Text("Ask Confirmation Before Quitting")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(TactileButtonStyle(pressedScale: 0.985, pressedOpacity: 0.78))
        .pointerStyle(.link)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredRowID = hovering ? "autoquit.confirm" : (hoveredRowID == "autoquit.confirm" ? nil : hoveredRowID)
        }
    }

    private var alertWhenQuitCheckboxRow: some View {
        let isHovered = (hoveredRowID == "autoquit.alert")

        return Button {
            manager.alertOnAppQuit.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: manager.alertOnAppQuit ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(manager.alertOnAppQuit ? Color.accentColor : Color.secondary)
                    .frame(width: 14, alignment: .center)

                Text("Alert When Apps Quit")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(TactileButtonStyle(pressedScale: 0.985, pressedOpacity: 0.78))
        .pointerStyle(.link)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredRowID = hovering ? "autoquit.alert" : (hoveredRowID == "autoquit.alert" ? nil : hoveredRowID)
        }
    }

    private var snoozeControlCenterRow: some View {
        let isSnoozed = manager.isTemporarilyPaused
        let isHovered = (hoveredRowID == "row.snooze")

        var titleText: String {
            if isSnoozed, let until = manager.pausedUntilDate, Date.now < until {
                let remaining = manager.formatFriendlyDuration(until.timeIntervalSinceNow)
                return "Paused (\(remaining) left)"
            }
            return "Pause Inactivity Timers"
        }

        var subtitleText: String {
            if isSnoozed {
                return "Click dropdown to change or resume"
            }
            return "Temporarily freeze all timers"
        }

        var pillLabel: String {
            if isSnoozed {
                return "Paused"
            }
            return manager.currentPausePreset.shortLabel
        }

        return HStack(spacing: 10) {
            // Icon button (quick toggle on icon tap)
            Button {
                if isSnoozed {
                    manager.resumeFromTemporaryPause()
                } else {
                    manager.pause(for: TimeInterval(manager.pauseDurationSeconds))
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(isSnoozed ? Color.orange : Color.primary.opacity(0.11))
                        .frame(width: 28, height: 28)
                        .animation(.easeInOut(duration: 0.2), value: isSnoozed)

                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isSnoozed ? Color.white : Color.primary.opacity(0.85))
                }
            }
            .buttonStyle(TactileButtonStyle(pressedScale: 0.92, pressedOpacity: 0.8))
            .pointerStyle(.link)
            .help(isSnoozed ? "Click to resume timers now" : "Click to pause timers for \(manager.currentPausePreset.descriptiveLabel)")

            // Middle text
            Button {
                if isSnoozed {
                    manager.resumeFromTemporaryPause()
                } else {
                    manager.pause(for: TimeInterval(manager.pauseDurationSeconds))
                }
            } label: {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(titleText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitleText)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Spacer(minLength: 4)

            // Right: Dropdown List Selector
            Menu {
                ForEach(PausePreset.allCases) { preset in
                    Button {
                        manager.pauseDurationSeconds = preset.rawValue
                        manager.pause(for: TimeInterval(preset.rawValue))
                    } label: {
                        HStack {
                            Text(preset.descriptiveLabel)
                            if manager.pauseDurationSeconds == preset.rawValue {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if isSnoozed {
                    Divider()
                    Button {
                        manager.resumeFromTemporaryPause()
                    } label: {
                        Label("Resume Timers Now", systemImage: "play.fill")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(pillLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSnoozed ? Color.orange : Color.primary.opacity(0.85))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSnoozed ? Color.orange.opacity(0.8) : Color.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSnoozed ? Color.orange.opacity(0.18) : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSnoozed ? Color.orange.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerStyle(.link)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.085) : Color.clear)
        )
        .padding(.horizontal, 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredRowID = hovering ? "row.snooze" : (hoveredRowID == "row.snooze" ? nil : hoveredRowID)
        }
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
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.75)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func controlCenterHeaderToggleRow(
        id: String,
        icon: String,
        isActive: Bool,
        activeTint: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onIconTap: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredRowID == id)

        HStack(spacing: 10) {
            Button(action: onIconTap) {
                ZStack {
                    Circle()
                        .fill(isActive ? activeTint : Color.primary.opacity(0.11))
                        .frame(width: 28, height: 28)
                        .animation(.easeInOut(duration: 0.2), value: isActive)

                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
                }
            }
            .buttonStyle(TactileButtonStyle(pressedScale: 0.92, pressedOpacity: 0.8))
            .pointerStyle(.link)

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

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .pointerStyle(.link)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.085) : Color.clear)
        )
        .padding(.horizontal, 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredRowID = hovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
    }

    @ViewBuilder
    private func controlCenterItemRow(
        id: String,
        icon: String,
        isActive: Bool,
        activeTint: Color,
        title: String,
        subtitle: String,
        onIconTap: @escaping () -> Void,
        onRowTap: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredRowID == id)

        HStack(spacing: 10) {
            Button(action: onIconTap) {
                ZStack {
                    Circle()
                        .fill(isActive ? activeTint : Color.primary.opacity(0.11))
                        .frame(width: 28, height: 28)
                        .animation(.easeInOut(duration: 0.2), value: isActive)

                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
                }
            }
            .buttonStyle(TactileButtonStyle(pressedScale: 0.92, pressedOpacity: 0.8))
            .pointerStyle(.link)

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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(pressedScale: 0.985, pressedOpacity: 0.78))
            .pointerStyle(.link)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.085) : Color.clear)
        )
        .padding(.horizontal, 6)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredRowID = hovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
    }

    @ViewBuilder
    private func submenuCheckmarkRow(
        id: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredRowID == id)

        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1.0 : 0.0)
                    .frame(width: 14, alignment: .center)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : (isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
            )
        }
        .buttonStyle(TactileButtonStyle(pressedScale: 0.985, pressedOpacity: 0.78))
        .pointerStyle(.link)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
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
        .buttonStyle(TactileButtonStyle(pressedScale: 0.985, pressedOpacity: 0.78))
        .pointerStyle(.link)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
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

// MARK: - Native Tactile Button Style

/// Interactive tactile feedback button style that gently scales and fades on mouse down.
public struct TactileButtonStyle: ButtonStyle {
    public var pressedScale: CGFloat = 0.985
    public var pressedOpacity: Double = 0.78

    public init(pressedScale: CGFloat = 0.985, pressedOpacity: Double = 0.78) {
        self.pressedScale = pressedScale
        self.pressedOpacity = pressedOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}


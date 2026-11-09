import AppKit
import SwiftUI

/// Native Control Center floating panel (like macOS Sound / Wi-Fi menu panels).
/// Uses `[.titled, .fullSizeContentView, .nonactivatingPanel]` with hidden titlebar buttons so
/// macOS WindowServer itself applies the hardware corner mask, native hairline rim border, and shadow.
@MainActor
private final class ControlCenterMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Custom `NSHostingView` that accepts the first mouse click immediately even when the app is not active,
/// and removes the default safe-area titlebar inset so content fills edge-to-edge.
@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Properties

    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var menuPanel: ControlCenterMenuPanel?
    private var menuHostingView: FirstMouseHostingView<MenuPopoverView>?
    private var currentMeasuredPanelHeight: CGFloat = 356
    private var lastPanelCloseUptime: TimeInterval = 0
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var localKeyMonitor: Any?
    private let autoHideManager = AutoHideManager()

    // MARK: - Entry Point

    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenuBar()
        setupControlCenterMenuPanel()
        applyAppearanceModes(initialLaunch: true)
        setupAndShowMainWindow()

        autoHideManager.onStateChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        autoHideManager.onAppearanceModeChange = { [weak self] in
            self?.applyAppearanceModes(initialLaunch: false)
        }

        // Allow automated UI verification to toggle/open the menu bar panel and export a visual snapshot
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.example.AutoHideAgent.debugOpenMenuPanel"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let snapshotPath = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem?.button else { return }
                self.openMenuPanel(relativeTo: button)
                let isKey = self.menuPanel?.isKeyWindow ?? false
                let isVis = self.menuPanel?.isVisible ?? false
                let frameStr = NSStringFromRect(self.menuPanel?.frame ?? .zero)
                let appActive = NSApplication.shared.isActive
                self.autoHideManager.appendLog(
                    .info,
                    "Menu panel opened (diagnostic check).",
                    technical: "isKey=\(isKey), isVisible=\(isVis), appActive=\(appActive), frame=\(frameStr)"
                )
                if let snapshotPath,
                   let hostingView = self.menuHostingView {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        hostingView.layoutSubtreeIfNeeded()
                        let bounds = hostingView.bounds
                        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: bounds) {
                            hostingView.cacheDisplay(in: bounds, to: rep)
                            if let pngData = rep.representation(using: .png, properties: [:]) {
                                try? pngData.write(to: URL(fileURLWithPath: snapshotPath))
                            }
                        }
                    }
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.example.AutoHideAgent.debugSnapshotMainWindow"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let snapshotPath = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, let snapshotPath, let contentView = self.mainWindow?.contentView else { return }
                self.showMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    contentView.layoutSubtreeIfNeeded()
                    let bounds = contentView.bounds
                    if let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) {
                        contentView.cacheDisplay(in: bounds, to: rep)
                        if let pngData = rep.representation(using: .png, properties: [:]) {
                            try? pngData.write(to: URL(fileURLWithPath: snapshotPath))
                        }
                    }
                }
            }
        }
    }

    /// Re-opens the main desktop window when the user clicks the Dock icon if the window was closed.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Keep the app running in the background when the user closes the main window (`Cmd+W`).
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Dynamic Dock & Menu Bar Presence

    private func applyAppearanceModes(initialLaunch: Bool) {
        let app = NSApplication.shared

        // 1. Dock & App Switcher presence (.regular vs .accessory)
        let targetPolicy: NSApplication.ActivationPolicy = autoHideManager.showInDock ? .regular : .accessory
        if app.activationPolicy() != targetPolicy {
            app.setActivationPolicy(targetPolicy)
            if targetPolicy == .regular {
                setupMainMenuBar()
                if !initialLaunch {
                    app.activate(ignoringOtherApps: true)
                    mainWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }

        // 2. Menu Bar Icon presence
        if autoHideManager.showInMenuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.target = self
                    button.action = #selector(handleStatusItemClick(_:))
                    button.sendAction(on: [.leftMouseDown, .rightMouseDown])
                }
                statusItem = item
            }
            updateStatusItemAppearance()
        } else {
            closeMenuPanel()
            if let existingItem = statusItem {
                NSStatusBar.system.removeStatusItem(existingItem)
                statusItem = nil
            }
        }
    }

    // MARK: - Setup Main Desktop Window

    private func setupAndShowMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AutoHide"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentViewController = NSHostingController(
            rootView: MainDashboardView(manager: autoHideManager)
        )

        self.mainWindow = window
        showMainWindow()
    }

    public func showMainWindow() {
        closeMenuPanel()
        guard let window = mainWindow else {
            setupAndShowMainWindow()
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Setup Standard macOS Menu Bar (AutoHide, Window)

    private func setupMainMenuBar() {
        let mainMenu = NSMenu()

        // 1. Application Menu ("AutoHide")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let openDashboardItem = NSMenuItem(
            title: "Open AutoHide Window",
            action: #selector(openDashboardFromMenu(_:)),
            keyEquivalent: "0"
        )
        openDashboardItem.target = self
        appMenu.addItem(openDashboardItem)

        let hideOthersNowItem = NSMenuItem(
            title: "Hide Background Apps Now",
            action: #selector(hideBackgroundAppsFromMenu(_:)),
            keyEquivalent: "h"
        )
        hideOthersNowItem.keyEquivalentModifierMask = [.command, .shift]
        hideOthersNowItem.target = self
        appMenu.addItem(hideOthersNowItem)

        let openLogItem = NSMenuItem(
            title: "Open Diagnostic Log File…",
            action: #selector(openLogFromMenu(_:)),
            keyEquivalent: "l"
        )
        openLogItem.target = self
        appMenu.addItem(openLogItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AutoHide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AutoHide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 2. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    @objc private func openDashboardFromMenu(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func hideBackgroundAppsFromMenu(_ sender: Any?) {
        autoHideManager.hideAllBackgroundAppsNow()
    }

    @objc private func openLogFromMenu(_ sender: Any?) {
        autoHideManager.openDiagnosticLogFile()
    }

    // MARK: - Setup Control Center Floating Menu Panel (Native WindowServer Rim & Corner Mask)

    private func setupControlCenterMenuPanel() {
        let panel = ControlCenterMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 308, height: 356),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        let rootView = MenuPopoverView(
            manager: autoHideManager,
            onOpenMainWindow: { [weak self] in
                self?.showMainWindow()
            },
            onClosePanel: { [weak self] in
                self?.closeMenuPanel()
            },
            onHeightChange: { [weak self] measuredHeight in
                guard let self else { return }
                let roundedHeight = ceil(measuredHeight)
                if abs(roundedHeight - self.currentMeasuredPanelHeight) > 0.5 {
                    self.currentMeasuredPanelHeight = roundedHeight
                    self.repositionAndResizeMenuPanel(animated: false)
                }
            }
        )

        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.safeAreaRegions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: 308, height: 356)
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView
        self.menuPanel = panel
        self.menuHostingView = hostingView
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let active = autoHideManager.isEnabled && !autoHideManager.isTemporarilyPaused
        let description: String
        if !autoHideManager.isEnabled {
            description = "AutoHide: Disabled"
        } else if autoHideManager.isTemporarilyPaused {
            description = "AutoHide: Snoozed for 1 Hour"
        } else {
            description = "AutoHide: Active (Right-click to Hide Others Now)"
        }

        button.image = makeMenuBarIcon(isEnabled: active)
        button.toolTip = description
        let isPanelOpen = (menuPanel?.isVisible == true)
        setStatusButtonHighlighted(isPanelOpen)
    }

    private func setStatusButtonHighlighted(_ highlighted: Bool) {
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = 5.5
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = highlighted
            ? NSColor.labelColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        button.highlight(highlighted)
    }

    /// Draws a custom, pixel-aligned 18x18 macOS menu bar template icon (front window + receding dashed window).
    private func makeMenuBarIcon(isEnabled: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let alpha: CGFloat = isEnabled ? 1.0 : 0.45

            // Back window (receding dashed outline)
            let backRect = CGRect(x: 6.5, y: 6.5, width: 9.5, height: 7.5)
            let backPath = NSBezierPath(roundedRect: backRect, xRadius: 1.8, yRadius: 1.8)
            NSColor.labelColor.withAlphaComponent(alpha * 0.65).setStroke()
            backPath.lineWidth = 1.2
            let dash: [CGFloat] = [2.0, 1.5]
            backPath.setLineDash(dash, count: 2, phase: 0)
            backPath.stroke()

            // Clear region behind front window so overlapping lines don't clutter
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let clearRect = CGRect(x: 1.2, y: 2.2, width: 10.6, height: 8.6)
            NSBezierPath(roundedRect: clearRect, xRadius: 2.0, yRadius: 2.0).fill()
            ctx.restoreGState()

            // Front window (solid crisp outline + title bar)
            let frontRect = CGRect(x: 2.0, y: 3.0, width: 9.5, height: 7.5)
            let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: 1.8, yRadius: 1.8)
            NSColor.labelColor.withAlphaComponent(alpha).setStroke()
            frontPath.lineWidth = 1.35
            frontPath.stroke()

            // Title bar line inside front window
            let titleBar = NSBezierPath()
            titleBar.move(to: CGPoint(x: frontRect.minX, y: frontRect.maxY - 2.3))
            titleBar.line(to: CGPoint(x: frontRect.maxX, y: frontRect.maxY - 2.3))
            titleBar.lineWidth = 1.1
            titleBar.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Bar Actions

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let currentEvent = NSApp.currentEvent
        // Right-clicking (or Control-clicking) the menu bar icon immediately hides all background apps!
        if currentEvent?.type == .rightMouseDown || currentEvent?.type == .rightMouseUp || (currentEvent?.modifierFlags.contains(.control) == true) {
            closeMenuPanel()
            autoHideManager.hideAllBackgroundAppsNow()
            return
        }

        if menuPanel?.isVisible == true {
            closeMenuPanel()
            return
        }

        // Guard against mouseDown on status item closing via monitor and immediately re-opening
        if ProcessInfo.processInfo.systemUptime - lastPanelCloseUptime < 0.2 {
            return
        }

        openMenuPanel(relativeTo: sender)
    }

    private func openMenuPanel(relativeTo sender: NSStatusBarButton) {
        if menuPanel == nil {
            setupControlCenterMenuPanel()
        }
        guard let panel = menuPanel, let hostingView = panel.contentView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = ceil(hostingView.fittingSize.height)
        if fittingHeight > 100 {
            currentMeasuredPanelHeight = fittingHeight
        }

        repositionAndResizeMenuPanel(animated: false)
        panel.alphaValue = 1.0
        panel.makeKeyAndOrderFront(nil)

        // Keep the menu bar icon background pill highlighted while the panel is open
        setStatusButtonHighlighted(true)
        DispatchQueue.main.async { [weak self] in
            if self?.menuPanel?.isVisible == true {
                self?.setStatusButtonHighlighted(true)
            }
        }

        // Re-assert status bar button highlight on mouseUp (since NSStatusBarButton clears highlight on mouseUp)
        if localMouseUpMonitor == nil {
            localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.menuPanel?.isVisible == true else { return }
                    DispatchQueue.main.async {
                        if self.menuPanel?.isVisible == true {
                            self.setStatusButtonHighlighted(true)
                        }
                    }
                }
                return event
            }
        }

        // Dismiss cleanly when clicking outside the panel in another app
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closeMenuPanel()
                }
            }
        }

        // Dismiss cleanly when clicking on our own main desktop window outside the menu panel
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.menuPanel, panel.isVisible else { return }
                    let statusWindow = self.statusItem?.button?.window
                    if event.window !== panel && event.window !== statusWindow {
                        self.closeMenuPanel()
                    }
                }
                return event
            }
        }

        // Dismiss on Escape key
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape
                    MainActor.assumeIsolated {
                        self?.closeMenuPanel()
                    }
                    return nil
                }
                return event
            }
        }
    }

    private func repositionAndResizeMenuPanel(animated: Bool) {
        guard let panel = menuPanel,
              let sender = statusItem?.button,
              let buttonWindow = sender.window else { return }

        let panelWidth: CGFloat = 308
        let panelHeight: CGFloat = max(240, currentMeasuredPanelHeight)

        let buttonFrameInWindow = sender.convert(sender.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var originX = round(buttonFrameOnScreen.midX - (panelWidth / 2.0))
        if screenFrame != .zero {
            originX = max(screenFrame.minX + 8, min(originX, screenFrame.maxX - panelWidth - 8))
        }
        let originY = round(buttonFrameOnScreen.minY - panelHeight - 5)
        let targetFrame = NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)

        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func closeMenuPanel() {
        setStatusButtonHighlighted(false)
        if let panel = menuPanel, panel.isVisible {
            lastPanelCloseUptime = ProcessInfo.processInfo.systemUptime
            panel.orderOut(nil)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let localMonitor = localClickMonitor {
            NSEvent.removeMonitor(localMonitor)
            localClickMonitor = nil
        }
        if let mouseUpMonitor = localMouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            localMouseUpMonitor = nil
        }
        if let keyMonitor = localKeyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            localKeyMonitor = nil
        }
    }
}

import AppKit
import SwiftUI
import UserNotifications

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

/// Container view with flipped coordinates (`isFlipped = true`) so (0, 0) is at the top-left.
/// Pins the SwiftUI hosting view to the top of the menu panel and prevents `NSHostingView`
/// from vertically centering its content during height expansion/collapse animations.
@MainActor
private final class ControlCenterContentView: NSView {
    override var isFlipped: Bool { true }

    var targetContentHeight: CGFloat = 356 {
        didSet {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    weak var hostingView: NSView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        hostingView?.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(bounds.height, targetContentHeight)
        )
    }
}

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Properties

    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var menuPanel: ControlCenterMenuPanel?
    private var menuContainerView: ControlCenterContentView?
    private var menuHostingView: FirstMouseHostingView<MenuPopoverView>?
    private var currentMeasuredPanelHeight: CGFloat = 660
    private var lastPanelCloseUptime: TimeInterval = 0
    private var menuPresentation = MenuBarPresentationState()
    private var isPanelClosing: Bool { menuPresentation.panelPhase == .closing }
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var localKeyMonitor: Any?
    private var benchmarkObserver: NSObjectProtocol?
    private let autoHideManager: AutoHideManager = {
        if AppRuntime.isDevelopment, CommandLine.arguments.contains("--dry-run"),
           ProcessInfo.processInfo.environment["AUTOHIDE_BENCHMARK_DIRECTORY"] != nil {
            let defaults = UserDefaults(suiteName: "AutoHideAgent.Benchmark.\(ProcessInfo.processInfo.processIdentifier)")!
            defaults.set(false, forKey: "com.systems.autohideagent.alertOnAppQuit")
            defaults.set(true, forKey: "com.systems.autohideagent.showInMenuBar")
            return AutoHideManager(defaults: defaults, dryRun: true)
        }
        return AutoHideManager()
    }()

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

        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
            if autoHideManager.alertOnAppHide || autoHideManager.alertOnAppQuit {
                autoHideManager.requestNotificationPermissionIfNeeded()
            }
        }

        benchmarkObserver = PerformanceHooks.install(manager: autoHideManager) { [weak self] scene in
            guard let self else { return }
            switch scene {
            case "dashboard": self.showMainWindow()
            case "menu":
                self.mainWindow?.orderOut(nil)
                if let button = self.statusItem?.button { self.openMenuPanel(relativeTo: button) }
            default:
                self.closeMenuPanel()
                self.mainWindow?.orderOut(nil)
            }
        }

        // Allow automated UI verification (only when launched with AUTOHIDE_DEBUG=1)
        if autoHideDebugHooksEnabled { installDebugHooks() }
    }

    private func installDebugHooks() {
        let prefix = autoHideManager.isDevBuild ? "com.systems.autohideagent.dev" : "com.systems.autohideagent"

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(prefix).debugOpenMenuPanel"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let snapshotPath = notification.object as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.statusItem == nil {
                    self.autoHideManager.showInMenuBar = true
                }
                guard let button = self.statusItem?.button else { return }
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
                   let containerView = self.menuContainerView {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        containerView.layoutSubtreeIfNeeded()
                        let bounds = containerView.bounds
                        if let rep = containerView.bitmapImageRepForCachingDisplay(in: bounds) {
                            containerView.cacheDisplay(in: bounds, to: rep)
                            if let pngData = rep.representation(using: .png, properties: [:]) {
                                try? pngData.write(to: URL(fileURLWithPath: snapshotPath))
                            }
                        }
                    }
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(prefix).debugSnapshotMainWindow"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let snapshotPath = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, let snapshotPath else { return }
                self.showMainWindow()
                guard let contentView = self.mainWindow?.contentView else { return }
                let targetView = contentView.superview ?? contentView
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    targetView.layoutSubtreeIfNeeded()
                    let bounds = targetView.bounds
                    if let rep = targetView.bitmapImageRepForCachingDisplay(in: bounds) {
                        targetView.cacheDisplay(in: bounds, to: rep)
                        if let pngData = rep.representation(using: .png, properties: [:]) {
                            try? pngData.write(to: URL(fileURLWithPath: snapshotPath))
                        }
                    }
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(prefix).debugCheckUpdates"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                UpdateController.shared.checkForUpdates()
            }
        }

        #if DEBUG
        // Exercise the actual AppKit lifecycle without scripting Accessibility or
        // changing another app. Available only in an explicitly enabled safe dev run.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(prefix).debugPresentationAction"),
            object: nil, queue: .main
        ) { [weak self] notification in
            let action = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, self.autoHideManager.isDevBuild, self.autoHideManager.isDryRunMode else { return }
                switch action {
                case "panel":
                    if let button = self.statusItem?.button { self.openMenuPanel(relativeTo: button) }
                case "closePanel": self.closeMenuPanel()
                case "dashboard": self.showMainWindow()
                case "minimize": self.mainWindow?.miniaturize(nil)
                case "closeDashboard": self.mainWindow?.close()
                case "deactivate": NSApp.deactivate()
                default: break
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(prefix).debugSnapshotPresentation"),
            object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, self.autoHideManager.isDevBuild, self.autoHideManager.isDryRunMode,
                      let path, let button = self.statusItem?.button else { return }
                // Read the rendered state without updating it, so a missed event is visible.
                let snapshot: [String: Any] = [
                    "panelPhase": String(describing: self.menuPresentation.panelPhase),
                    "panelVisible": self.menuPanel?.isVisible == true,
                    "dashboardVisible": self.mainWindow?.isVisible == true,
                    "dashboardKey": self.mainWindow?.isKeyWindow == true,
                    "dashboardMiniaturized": self.mainWindow?.isMiniaturized == true,
                    "applicationActive": NSApp.isActive,
                    "backgroundHighlighted": (button.layer?.backgroundColor?.alpha ?? 0) > 0,
                    "nativeHighlighted": button.cell?.isHighlighted == true
                ]
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                    button.cacheDisplay(in: button.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path + ".png"))
                    }
                }
            }
        }
        #endif

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(prefix).debugPause"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let str = notification.object as? String
            let seconds = Double(str ?? "3600") ?? 3600
            MainActor.assumeIsolated {
                self?.autoHideManager.pause(for: seconds)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        autoHideManager.finishDiagnosticLog()
        if let benchmarkObserver { DistributedNotificationCenter.default().removeObserver(benchmarkObserver) }
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

    private final class AutoHideDashboardWindow: NSWindow {
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown && event.clickCount == 2 {
                let loc = event.locationInWindow
                let topBarHeight: CGFloat = 54
                let isTopBar = loc.y >= frame.height - topBarHeight && loc.y <= frame.height
                if isTopBar && loc.x > 75 {
                    if let hit = contentView?.hitTest(loc) {
                        let className = NSStringFromClass(type(of: hit))
                        let isTableOrRow = className.contains("Table") || className.contains("Row") || className.contains("Cell")
                        let isInteractive = hit is NSButton || hit is NSTextField || hit is NSControl ||
                                            className.contains("Button") || className.contains("TextField") || isTableOrRow
                        if !isInteractive {
                            self.performZoom(nil)
                            return
                        }
                    } else {
                        self.performZoom(nil)
                        return
                    }
                }
            }
            super.sendEvent(event)
        }
    }

    private func setupAndShowMainWindow() {
        let window = AutoHideDashboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let appTitle = autoHideManager.isDevBuild ? "AutoHideAgent Dev" : "AutoHideAgent"
        window.identifier = NSUserInterfaceItemIdentifier(AppRuntime.dashboardWindowIdentifier)
        window.title = autoHideManager.isDryRunMode ? "\(appTitle) (Dry Run)" : appTitle
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentViewController = NSHostingController(
            rootView: MainDashboardView(manager: autoHideManager)
        )

        self.mainWindow = window
        showMainWindow()
        configureNonCollapsibleSidebar()
    }

    private func configureNonCollapsibleSidebar() {
        guard mainWindow != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.mainWindow, let contentView = window.contentView else { return }
                @MainActor func findSplitView(in view: NSView) -> NSSplitView? {
                    if let sv = view as? NSSplitView { return sv }
                    for sub in view.subviews {
                        if let found = findSplitView(in: sub) { return found }
                    }
                    return nil
                }
                if let sv = findSplitView(in: contentView), let svc = sv.delegate as? NSSplitViewController {
                    if let sidebarItem = svc.splitViewItems.first {
                        sidebarItem.canCollapse = false
                        sidebarItem.minimumThickness = 230
                        if sidebarItem.viewController.view.frame.width < 230 {
                            sv.setPosition(245, ofDividerAt: 0)
                        }
                    }
                }
            }
        }
    }

    public func showMainWindow() {
        closeMenuPanel()
        guard let window = mainWindow else {
            setupAndShowMainWindow()
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Setup Standard macOS Menu Bar (AutoHideAgent, Window)

    private func setupMainMenuBar() {
        let mainMenu = NSMenu()

        // 1. Application Menu ("AutoHideAgent")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let openDashboardItem = NSMenuItem(
            title: "Open AutoHideAgent Window",
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

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesFromMenu(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        appMenu.addItem(checkForUpdatesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AutoHideAgent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AutoHideAgent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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

    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        UpdateController.shared.checkForUpdates()
    }

    // MARK: - Setup Control Center Floating Menu Panel (Native WindowServer Rim & Corner Mask)

    private func setupControlCenterMenuPanel() {
        let panel = ControlCenterMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 308, height: 660),
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
        panel.delegate = self

        let containerView = ControlCenterContentView()
        containerView.frame = NSRect(x: 0, y: 0, width: 308, height: 660)
        containerView.autoresizingMask = [.width, .height]
        containerView.targetContentHeight = 660
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true

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
                    self.menuContainerView?.targetContentHeight = roundedHeight
                    self.repositionAndResizeMenuPanel(animated: self.menuPanel?.isVisible == true)
                }
            }
        )

        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.safeAreaRegions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: 308, height: 660)

        containerView.hostingView = hostingView
        containerView.addSubview(hostingView)

        panel.contentView = containerView
        self.menuPanel = panel
        self.menuHostingView = hostingView
        self.menuContainerView = containerView
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let active = autoHideManager.isEnabled && !autoHideManager.isTemporarilyPaused
        let description: String
        if !autoHideManager.isEnabled {
            description = "AutoHideAgent: Disabled"
        } else if autoHideManager.isTemporarilyPaused {
            description = "AutoHideAgent: Snoozed for 1 Hour"
        } else {
            description = "AutoHideAgent: Active (Right-click to Hide Others Now)"
        }

        button.image = makeMenuBarIcon(isEnabled: active)
        button.toolTip = description
        updateStatusButtonHighlight()
    }

    /// Both presentations share one selection state. A visible background dashboard
    /// does not select the menu icon; the desktop window must actually have focus.
    private func updateStatusButtonHighlight(excluding window: NSWindow? = nil) {
        let dashboardFocused = mainWindow.map {
            $0 !== window && $0.isVisible && !$0.isMiniaturized && $0.isKeyWindow && NSApp.isActive
        } ?? false
        setStatusButtonHighlighted(menuPresentation.shouldHighlight(
            panelIsVisible: menuPanel?.isVisible == true,
            dashboardIsFocused: dashboardFocused
        ))
    }

    private func refreshStatusButtonHighlightAfterFocusChange() {
        updateStatusButtonHighlight()
        // AppKit may update the status button or key window later in this event.
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusButtonHighlight()
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func applicationDidResignActive(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func applicationDidHide(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func applicationDidUnhide(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func windowDidResignKey(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        refreshStatusButtonHighlightAfterFocusChange()
    }

    public func windowWillClose(_ notification: Notification) {
        updateStatusButtonHighlight(excluding: notification.object as? NSWindow)
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusButtonHighlight()
        }
    }

    private func setStatusButtonHighlighted(_ highlighted: Bool) {
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = max(button.bounds.height, 22) / 2
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = highlighted
            ? NSColor.labelColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        button.highlight(highlighted)
    }

    /// Native SF Symbol menu bar icon (matches weight/size of Apple's own menu extras).
    private func makeMenuBarIcon(isEnabled: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular, scale: .medium)
        let name = isEnabled ? "macwindow.on.rectangle" : "macwindow"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AutoHideAgent")?
            .withSymbolConfiguration(config) ?? NSImage()
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

        if menuPanel?.isVisible == true && !isPanelClosing {
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
        guard let panel = menuPanel else { return }

        menuPresentation.openPanel()
        panel.contentView?.layer?.removeAllAnimations()
        menuHostingView?.layer?.removeAllAnimations()

        menuHostingView?.layoutSubtreeIfNeeded()
        if let fittingHeight = menuHostingView?.fittingSize.height, fittingHeight > 100 {
            currentMeasuredPanelHeight = ceil(fittingHeight)
            menuContainerView?.targetContentHeight = currentMeasuredPanelHeight
        }

        repositionAndResizeMenuPanel(animated: false)
        let finalFrame = panel.frame
        let startFrame = NSRect(
            x: finalFrame.origin.x,
            y: finalFrame.origin.y + 6,
            width: finalFrame.width,
            height: finalFrame.height
        )
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0.0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1.0
        }

        refreshStatusButtonHighlightAfterFocusChange()

        // Mouse-up clears AppKit's pressed appearance; reapply the current shared
        // state, rather than capturing an obsolete "panel open" value.
        if localMouseUpMonitor == nil {
            localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.refreshStatusButtonHighlightAfterFocusChange()
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
        let topY = round(buttonFrameOnScreen.minY - 5)
        let originY = topY - panelHeight
        let targetFrame = NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)

        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func closeMenuPanel() {
        if let panel = menuPanel, panel.isVisible, !isPanelClosing {
            let transitionID = menuPresentation.beginClosingPanel()
            updateStatusButtonHighlight()
            lastPanelCloseUptime = ProcessInfo.processInfo.systemUptime
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.menuPresentation.finishClosingPanel(transitionID: transitionID) else { return }
                    panel.orderOut(nil)
                    panel.alphaValue = 1.0
                    self.refreshStatusButtonHighlightAfterFocusChange()
                }
            }
        }
        updateStatusButtonHighlight()
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

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

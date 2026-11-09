import AppKit
import SwiftUI

/// Borderless, non-activating Control Center floating panel (like macOS Sound / Wi-Fi menu panels).
/// Appears immediately below the menu bar icon with a 14pt continuous corner radius, native `.menu`
/// blur material, and zero triangle arrow (`▲`), without stealing focus from the active application.
@MainActor
private final class ControlCenterMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Properties

    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var menuPanel: ControlCenterMenuPanel?
    private var menuHostingView: NSHostingView<MenuPopoverView>?
    private var globalClickMonitor: Any?
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
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
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
        window.setFrameAutosaveName("AutoHideMainWindow")
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

    // MARK: - Setup Control Center Floating Menu Panel (No Triangle Beak)

    private func setupControlCenterMenuPanel() {
        let panel = ControlCenterMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 308, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        // Frosted Control Center .menu visual effect surface with 14pt continuous corner radius
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 308, height: 320))
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.85
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let rootView = MenuPopoverView(
            manager: autoHideManager,
            onOpenMainWindow: { [weak self] in
                self?.showMainWindow()
            },
            onClosePanel: { [weak self] in
                self?.closeMenuPanel()
            },
            onLayoutChange: { [weak self] in
                self?.repositionAndResizeMenuPanel(animated: true)
            }
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        panel.contentView = visualEffect
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
        if currentEvent?.type == .rightMouseUp || (currentEvent?.modifierFlags.contains(.control) == true) {
            autoHideManager.hideAllBackgroundAppsNow()
            return
        }

        if menuPanel?.isVisible == true {
            closeMenuPanel()
        } else {
            openMenuPanel(relativeTo: sender)
        }
    }

    private func openMenuPanel(relativeTo sender: NSStatusBarButton) {
        if menuPanel == nil {
            setupControlCenterMenuPanel()
        }
        guard let panel = menuPanel else { return }

        // Highlight status bar button while panel is open, matching Apple Control Center
        sender.highlight(true)

        repositionAndResizeMenuPanel(animated: false)
        panel.alphaValue = 0.0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        // Dismiss cleanly when clicking anywhere outside the panel
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closeMenuPanel()
                }
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
              let hostingView = menuHostingView,
              let sender = statusItem?.button,
              let buttonWindow = sender.window else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let panelWidth: CGFloat = 308
        let panelHeight: CGFloat = max(210, fittingSize.height)

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
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func closeMenuPanel() {
        statusItem?.button?.highlight(false)
        if let panel = menuPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let keyMonitor = localKeyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            localKeyMonitor = nil
        }
    }
}

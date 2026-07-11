import Cocoa

@main
enum DictlyMain {
    static func main() {
        AppDiagnostics.shared.start()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        // Hold a strong reference so the delegate isn't released before the runloop starts.
        // NSApplication only holds it weakly.
        objc_setAssociatedObject(app, &DictlyMain.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.delegate = delegate
        app.run()
    }
    private static var delegateKey: UInt8 = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    static let log = AppLogger(category: "App")

    private var menuBarController: MenuBarController?
    private var dictationCoordinator: DictationCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Self.log.notice("Application did finish launching")

        let coordinator = DictationCoordinator()
        self.dictationCoordinator = coordinator

        let menuBar = MenuBarController(coordinator: coordinator)
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onShowOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onShowAbout = { [weak self] in self?.showAbout() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
        self.menuBarController = menuBar

        // Let the HUD anchor itself under our menu-bar icon when the user picks the
        // "top of screen" position.
        coordinator.hud.statusItemFrameProvider = { [weak menuBar] in
            menuBar?.statusItemScreenFrame()
        }

        // Always boot the coordinator (loads the bundled model in the background, starts the
        // hotkey monitor). Onboarding shows on top of that flow if needed.
        coordinator.start()

        if !Settings.shared.didCompleteOnboarding {
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    // MARK: - Dock icon lifecycle

    // Dictly is a menu-bar (LSUIElement) app, but showing Settings, About or
    // Onboarding switches the activation policy to .regular so the window gets
    // a Dock icon and normal focus. Switch back once the last real window is
    // gone — otherwise the Dock icon lingers forever (the onboarding "Done"
    // path used to be the only one that cleaned up after itself).
    //
    // A watchdog timer, not NSWindow.willCloseNotification: the standard About
    // panel disappears without ever posting willClose, so a notification-based
    // revert misses it. The timer only runs while the Dock icon is showing.
    private var dockIconWatchdog: Timer?

    private func showDockIcon() {
        NSApp.setActivationPolicy(.regular)
        guard dockIconWatchdog == nil else { return }
        dockIconWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSApp.activationPolicy() == .regular {
                // The HUD doesn't keep the icon alive: it's a panel that can't
                // become key. Neither do closed-but-retained controller windows —
                // they are no longer visible. A minimized window counts as open:
                // it reports isVisible == false, but its Dock tile is the user's
                // only way back to it, so the icon must survive minimize.
                let anyRealWindowVisible = NSApp.windows.contains {
                    $0.isMiniaturized || ($0.isVisible && $0.canBecomeKey)
                }
                guard !anyRealWindowVisible else { return }
                NSApp.setActivationPolicy(.accessory)
            }
            self.dockIconWatchdog?.invalidate()
            self.dockIconWatchdog = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.log.notice("Application will terminate")
        AppDiagnostics.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(coordinator: dictationCoordinator!)
        }
        showDockIcon()
        guard let win = settingsWindowController?.window else { return }
        Self.centerOnActiveScreen(win)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(coordinator: dictationCoordinator!) { [weak self] in
                Settings.shared.didCompleteOnboarding = true
                self?.onboardingWindowController?.close()
                self?.onboardingWindowController = nil
                // No explicit switch back to .accessory here: the dock-icon
                // watchdog reverts once the last real window is gone. Forcing it
                // here would strip the Dock icon while e.g. Settings is still open.
                self?.dictationCoordinator?.start()
            }
        }
        showDockIcon()
        guard let win = onboardingWindowController?.window else { return }
        Self.centerOnActiveScreen(win)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAbout() {
        showDockIcon()
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func centerOnActiveScreen(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { window.center(); return }

        // Clamp the window to the visible area before centring. The onboarding
        // window is tall (790 pt); on smaller laptops an un-clamped tall window
        // spills its title bar above the menu bar and its CTA below the Dock —
        // which reads to users as "the onboarding never opened" (reported after
        // a fresh install). Keeping it within the visible frame guarantees the
        // whole window — including the Continue button — is reachable.
        let margin: CGFloat = 24
        var size = window.frame.size
        size.width  = min(size.width,  visible.width  - margin)
        size.height = min(size.height, visible.height - margin)

        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

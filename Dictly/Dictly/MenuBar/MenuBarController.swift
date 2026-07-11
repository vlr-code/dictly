import AppKit
import Combine

/// Status-bar entry point. Reflects coordinator phase as one of four brand icons
/// (handoff §3) and exposes Settings / Onboarding / About / Quit.
///
/// `idle` and `processing` ship as template images — AppKit re-tints them to follow the
/// menu-bar appearance (white on dark bar, black on light bar). `recording` (red accent
/// dot) and `disabled` (red slash) are colored, so they're set as non-template.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private weak var coordinator: DictationCoordinator?
    private let statusItem: NSStatusItem
    private var subscriptions = Set<AnyCancellable>()
    private var processingAnimationTimer: Timer?
    private var statusMenuItem: NSMenuItem?
    private let micMenu = NSMenu()

    var onShowSettings: (() -> Void)?
    var onShowOnboarding: (() -> Void)?
    var onShowAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Frame of the status-item button in screen coordinates. Used by the HUD to
    /// anchor itself under the icon in "top" position mode. Returns `nil` if the item
    /// isn't on-screen yet.
    func statusItemScreenFrame() -> NSRect? {
        statusItem.button?.window?.frame
    }

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func install() {
        applyAsset(named: "MenuBar-idle", template: true)

        let menu = NSMenu()
        let status = NSMenuItem(title: "Dictly Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)),
                                keyEquivalent: ",").configured { $0.target = self })
        menu.addItem(NSMenuItem(title: "Permissions…",
                                action: #selector(showOnboarding(_:)),
                                keyEquivalent: "").configured { $0.target = self })

        // Microphone picker — submenu rebuilt on open (devices come and go).
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About Dictly", action: #selector(about(_:)),
                                keyEquivalent: "").configured { $0.target = self })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dictly", action: #selector(quit(_:)),
                                keyEquivalent: "q").configured { $0.target = self })
        statusItem.menu = menu

        coordinator?.phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.reflect(phase: phase) }
            .store(in: &subscriptions)

        // Show the active dictation language (flag / "auto") next to the icon and
        // keep it in sync as the user switches languages or toggles the feature.
        statusItem.button?.imagePosition = .imageLeading
        Settings.shared.didChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateLanguageIndicator() }
            .store(in: &subscriptions)
        updateLanguageIndicator()
    }

    /// When language switching is enabled, show the active language beside the
    /// icon: a flag emoji, or "auto" for auto-detect. Hidden otherwise.
    private func updateLanguageIndicator() {
        guard let button = statusItem.button else { return }
        if Settings.shared.secondaryLanguageEnabled {
            button.title = " " + LanguageOption.menuBarLabel(for: Settings.shared.activeLanguage)
        } else {
            button.title = ""
        }
    }

    private func reflect(phase: DictationCoordinator.Phase) {
        let title: String
        let asset: String
        let template: Bool
        let animateProcessing: Bool

        switch phase {
        case .idle:
            asset = "MenuBar-idle"; template = true; animateProcessing = false
            title = "Dictly Ready"
        case .modelLoading(let p):
            asset = "MenuBar-processing"; template = true; animateProcessing = true
            title = String(format: "Loading model · %.0f%%", p * 100)
        case .recording:
            asset = "MenuBar-recording"; template = false; animateProcessing = false
            title = "Listening"
        case .transcribing:
            asset = "MenuBar-processing"; template = true; animateProcessing = true
            title = "Transcribing"
        case .inserted:
            asset = "MenuBar-idle"; template = true; animateProcessing = false
            title = "Inserted"
        case .error(let msg):
            asset = "MenuBar-disabled"; template = false; animateProcessing = false
            title = "Error · \(msg)"
        }

        applyAsset(named: asset, template: template)
        statusMenuItem?.title = title

        if animateProcessing { startProcessingAnimation() } else { stopProcessingAnimation() }
    }

    private func applyAsset(named: String, template: Bool) {
        guard let button = statusItem.button else { return }
        let image = NSImage(named: named)
        image?.isTemplate = template
        button.image = image
        button.contentTintColor = nil   // template icons inherit bar color natively
    }

    /// "processing" / "loading" — pulse the icon's alpha for a sense of motion. Combines
    /// with the three-dot static glyph from `MenuBar-processing` to give a subtle
    /// "thinking…" effect without re-rendering animation frames.
    private func startProcessingAnimation() {
        guard processingAnimationTimer == nil else { return }
        let button = statusItem.button
        button?.alphaValue = 1.0
        processingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in
                guard let b = button else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    b.animator().alphaValue = b.alphaValue > 0.7 ? 0.4 : 1.0
                }
            }
        }
    }

    private func stopProcessingAnimation() {
        processingAnimationTimer?.invalidate()
        processingAnimationTimer = nil
        statusItem.button?.alphaValue = 1.0
    }

    // MARK: - Microphone picker

    /// Rebuild the mic submenu each time it's about to open so freshly
    /// connected/removed devices show up: every current input device, with a
    /// checkmark on the one that is the system default input right now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        menu.removeAllItems()

        // Selection works by changing the SYSTEM default input (see `selectMic`) —
        // machine-wide, every app follows. Say so instead of surprising the user.
        let hint = NSMenuItem(title: "Sets the Mac's default microphone", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let devices = AudioDeviceManager.inputDevices()
        guard !devices.isEmpty else {
            let none = NSMenuItem(title: "No input devices found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        let currentDefault = AudioDeviceManager.defaultInputDeviceID()
        for dev in devices {
            let item = NSMenuItem(title: dev.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.uid
            item.state = (dev.id == currentDefault) ? .on : .off   // ✓ on the active input
            menu.addItem(item)
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        // Picking a mic sets it as the system default input; the recording engine
        // then follows it. (We don't per-app rebind via AUHAL — that wouldn't
        // re-engage proxied devices, which is the whole bug we're working around.)
        guard let uid = sender.representedObject as? String,
              let id = AudioDeviceManager.deviceID(forUID: uid) else { return }
        AudioDeviceManager.setDefaultInputDevice(id)
    }

    @objc private func showSettings(_ sender: Any?) { onShowSettings?() }
    @objc private func showOnboarding(_ sender: Any?) { onShowOnboarding?() }
    @objc private func quit(_ sender: Any?) { onQuit?() }
    @objc private func about(_ sender: Any?) { onShowAbout?() }
}

private extension NSMenuItem {
    func configured(_ block: (NSMenuItem) -> Void) -> NSMenuItem {
        block(self); return self
    }
}

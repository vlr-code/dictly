import AppKit
import Combine

/// Top-level orchestrator. Holds the long-lived components and routes the
/// hotkey → record → transcribe → insert pipeline.
@MainActor
final class DictationCoordinator {

    private static let log = AppLogger(category: "Coordinator")

    enum Phase: Equatable {
        case idle
        case modelLoading(progress: Double)
        case recording
        case transcribing
        case inserted
        case error(String)
    }

    let hotkey = HotkeyManager()
    /// Optional second hotkey pinned to `Settings.secondaryLanguage` (GitHub #1).
    let secondaryHotkey = HotkeyManager()
    let recorder = AudioRecorder()
    let inserter = TextInserter()
    let hud = RecordingHUDController()
    private(set) var transcriber: Transcriber = TranscriberFactory.make()
    private(set) var postProcessor: TextPostProcessor = BasicPostProcessor()

    /// Published phase for UI subscribers (HUD, settings, menu bar).
    let phase = CurrentValueSubject<Phase, Never>(.idle)

    private var subscriptions = Set<AnyCancellable>()
    private(set) var isModelReady = false
    private var transcribeTask: Task<Void, Never>?

    /// Polls for Accessibility while a modifier-only hotkey is set but not yet
    /// trusted, so we can re-register the global monitor the moment it's granted —
    /// no app relaunch required.
    private var accessibilityWatchTimer: Timer?

    /// Whether we've already shown the "grant Accessibility" alert this session,
    /// so a user who's chosen "Not Now" isn't nagged on every dictation.
    private var didPromptAccessibilityThisSession = false

    /// Same, for the "your modifier-only hotkey needs Accessibility" startup warning.
    private var didWarnModifierHotkeyThisSession = false

    init() {
        bind()
    }

    private func bind() {
        Settings.shared.didChange
            .sink { [weak self] in self?.applySettings() }
            .store(in: &subscriptions)

        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }

        // The secondary hotkey doesn't record — it flips the active dictation
        // language between the two chosen languages (GitHub #1).
        secondaryHotkey.onPress = { [weak self] in self?.toggleActiveLanguage() }

        // Audio level updates flow straight to the HUD — they're a per-buffer
        // signal (10–40 Hz) that no other subscriber consumes. Re-emitting them
        // through `phase` made the menu-bar controller re-render its icon /
        // tooltip at audio rate for nothing. The HUD waveform itself is the
        // only meaningful consumer; it gates by its own `.live` style internally.
        recorder.onLevel = { [weak self] level in
            self?.hud.update(level: level)
        }
    }

    func start() {
        applySettings()
        hotkey.start()
        // Deferred to the next runloop tick so a modal alert never blocks launch.
        DispatchQueue.main.async { [weak self] in self?.warnIfModifierHotkeyNeedsAccessibility() }
        Task { await prepareModelInBackground() }
    }

    func stop() {
        hotkey.stop()
        secondaryHotkey.stop()
        transcribeTask?.cancel()
    }

    private func applySettings() {
        // This runs on EVERY Settings.didChange — including from the language-switch
        // hotkey's own callback, while the user may still be HOLDING the push-to-talk
        // key — so it must reconcile without churning: `update` no-ops when the combo
        // is unchanged, and start/stop happen only on actual enable-state transitions.
        hotkey.update(combo: Settings.shared.hotkey)

        if Settings.shared.secondaryLanguageEnabled {
            secondaryHotkey.update(combo: Settings.shared.secondaryHotkey)
            if !secondaryHotkey.isRunning { secondaryHotkey.start() }
        } else {
            secondaryHotkey.stop()
        }

        // Keep-warm mic (instant starts + pre-roll). The recorder itself checks
        // mic permission and skips Bluetooth inputs.
        recorder.setWarmMode(Settings.shared.keepMicWarm)

        // Re-evaluate the Accessibility watch (the active hotkey may have changed
        // to/from a modifier-only combo).
        startAccessibilityWatchIfNeeded()
    }

    /// Translate raw Core Audio / AVFoundation errors into something a user can act on.
    /// AVAudioEngine surfaces OSStatus codes via `(com.apple.coreaudio.avfaudio error N.)`
    /// strings that are meaningless without a reference table.
    private static func friendlyAudioErrorMessage(for error: NSError) -> String {
        switch error.code {
        case -10868:
            // kAudioFormatUnsupportedFormatError — most often a transient route
            // change (BT pairing, another app releasing the mic). We already retry
            // once internally; reaching this branch means the second try also failed.
            return "Mic unavailable — try again"
        case -10851, -10877:
            // kAudioUnitErr_InvalidProperty / NoConnection — input device gone away.
            return "Mic disconnected"
        case -10863:
            // kAudioHardwareNotRunningError
            return "Audio system not ready — try again"
        default:
            return "Couldn't start recording"
        }
    }

    func prepareModelInBackground() async {
        let id = Settings.shared.modelID
        Self.log.info("Preparing model \(id)")
        phase.send(.modelLoading(progress: 0))
        do {
            try await transcriber.prepare(modelID: id) { [weak self] p in
                self?.phase.send(.modelLoading(progress: p))
            }
            isModelReady = true
            phase.send(.idle)
        } catch {
            Self.log.error("Model load failed: \(error.localizedDescription)")
            phase.send(.error(error.localizedDescription))
        }
    }

    // MARK: Hotkey routing

    private func hotkeyPressed() {
        switch Settings.shared.hotkeyMode {
        case .pushToTalk:
            beginRecording()
        case .toggle:
            if recorder.state == .recording {
                endRecordingAndTranscribe()
            } else {
                beginRecording()
            }
        }
    }

    /// Flip the active dictation language between the two chosen languages. Fires
    /// `didChange`, which refreshes the menu-bar language indicator (the visible
    /// feedback the user sees next to the icon).
    private func toggleActiveLanguage() {
        guard Settings.shared.secondaryLanguageEnabled else { return }
        Settings.shared.secondaryLanguageActive.toggle()
        Self.log.info("Active language switched to \(Settings.shared.activeLanguage)")
    }

    private func hotkeyReleased() {
        guard Settings.shared.hotkeyMode == .pushToTalk else { return }
        // Read the recorder's own state — the phase may not have caught up yet on a very
        // quick tap (the engine takes a few ms to deliver the first level update).
        if recorder.state == .recording { endRecordingAndTranscribe() }
    }

    // MARK: Recording

    private func beginRecording() {
        guard isModelReady else {
            hud.flash(message: "Loading model…")
            return
        }
        guard PermissionsChecker.microphoneStatus == .authorized else {
            Task {
                let ok = await PermissionsChecker.requestMicrophone()
                if ok { self.beginRecording() }
                else { self.hud.flash(message: "Microphone access denied") }
            }
            return
        }

        do {
            try recorder.start()
            // Go straight to "Listening" — the first audible buffer typically arrives
            // <100 ms after `engine.start()` on built-in / wired mics, and showing an
            // intermediate "Connecting…" state for that window felt sluggish next to
            // tools like the original Whisper. On Bluetooth (SCO) the user may lose
            // ~200–400 ms of leading speech while the voice profile is being set up,
            // but that's the same trade-off every other dictation app makes.
            phase.send(.recording)
            if Settings.shared.showHUD { hud.show(state: .recording) }
        } catch {
            let nsError = error as NSError
            Self.log.error("recorder.start failed: code=\(nsError.code) domain=\(nsError.domain) desc=\(error.localizedDescription)")
            let friendly = Self.friendlyAudioErrorMessage(for: nsError)
            phase.send(.error(friendly))
            hud.show(state: .error(friendly))
            hud.hideAfter(seconds: 1.9)
            phase.send(.idle)
        }
    }

    private func endRecordingAndTranscribe() {
        let samples = recorder.stop()
        let durationSec = Double(samples.count) / AudioRecorder.targetSampleRate
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        Self.log.info("endRecording: \(samples.count) samples (\(String(format: "%.2f", durationSec))s)")

        // Whisper needs a real chunk of audio to detect speech reliably. A 100 ms tap on
        // the hotkey produces under that, and the model returns empty — surface a hint
        // instead of "Silence" so the user knows to hold longer. Judge the hold by
        // LIVE audio only: the keep-warm pre-roll pads every take with up to half a
        // second captured before the press, which would let an accidental tap slip
        // past this guard and transcribe ambient noise.
        let liveDurationSec = Double(samples.count - recorder.lastPreRollCount) / AudioRecorder.targetSampleRate
        if liveDurationSec < 0.4 {
            phase.send(.error("Hold longer"))
            hud.show(state: .error("Hold the hotkey while you speak"))
            hud.hideAfter(seconds: 1.9)
            phase.send(.idle)
            return
        }

        let language = Settings.shared.activeLanguage
        let fallbackCount = Settings.shared.transcriptionQuality.fallbackCount
        phase.send(.transcribing)
        if Settings.shared.showHUD { hud.show(state: .transcribing) }

        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            await self?.runTranscription(samples: samples, language: language,
                                          fallbackCount: fallbackCount,
                                          pipelineStart: pipelineStart)
        }
    }

    /// Shown once per session when auto-paste is blocked by missing Accessibility.
    /// A modal alert is far harder to miss than the HUD flash, and gives the user
    /// a one-click path to System Settings.
    private func promptAccessibilityOnce() {
        guard !didPromptAccessibilityThisSession else { return }
        didPromptAccessibilityThisSession = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dictly can't paste automatically yet"
        alert.informativeText = """
        Your dictation was copied to the clipboard — press ⌘V to paste it.

        To let Dictly type into apps for you, grant it Accessibility access in \
        System Settings → Privacy & Security → Accessibility, then add Dictly.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")

        // The app is a menu-bar agent (.accessory); bring it forward so the alert
        // is visible above whatever the user was dictating into.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            PermissionsChecker.promptAccessibilityIfNeeded(reason: "dictation-blocked")
            PermissionsChecker.openAccessibilitySettings()
        }
    }

    /// A global `NSEvent` key monitor (the modifier-only hotkey path) only starts
    /// receiving events once the app is trusted for Accessibility — and a monitor
    /// installed *before* the grant stays dead. So while a modifier-only hotkey is
    /// set but not trusted, poll; the instant access is granted, re-register the
    /// monitors so the hotkey works without an app relaunch.
    private func startAccessibilityWatchIfNeeded() {
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
        // Watch whenever ANY enabled hotkey is modifier-only — the language-switch
        // hotkey's default (right ⌥) needs the grant exactly like a modifier-only
        // push-to-talk key. Carbon key-combos don't need it.
        let needsAccessibility = Settings.shared.hotkey.kind == .modifierOnly
            || (Settings.shared.secondaryLanguageEnabled
                && Settings.shared.secondaryHotkey.kind == .modifierOnly)
        guard needsAccessibility else { return }
        guard !PermissionsChecker.isAccessibilityGranted else { return }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reRegisterHotkeysIfNowTrusted() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityWatchTimer = timer
    }

    private func reRegisterHotkeysIfNowTrusted() {
        guard PermissionsChecker.isAccessibilityGranted else { return }
        // Re-registering stops/starts the hotkeys, which would swallow the pending
        // push-to-talk release if a recording is in flight. Let the next tick do it.
        guard recorder.state != .recording else { return }
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
        Self.log.notice("Accessibility granted — re-registering hotkey monitors")
        hotkey.stop();  hotkey.start()
        if Settings.shared.secondaryLanguageEnabled {
            secondaryHotkey.stop(); secondaryHotkey.start()
        }
    }

    /// At launch, if any enabled hotkey is modifier-only (Fn, right Option…) and
    /// Accessibility isn't granted, its global key monitor receives nothing and the
    /// hotkey silently does nothing — the most confusing failure mode in the app.
    /// That covers BOTH the push-to-talk key and the optional language-switch key
    /// (whose default, right ⌥, is modifier-only too). Warn once, with a path to
    /// fix it. Key-combo hotkeys use Carbon and need no permission, so they're exempt.
    private func warnIfModifierHotkeyNeedsAccessibility() {
        guard Settings.shared.didCompleteOnboarding else { return }   // onboarding already covers this
        guard !didWarnModifierHotkeyThisSession else { return }
        guard !PermissionsChecker.isAccessibilityGranted else { return }

        let primaryDead = Settings.shared.hotkey.kind == .modifierOnly
        let secondaryDead = Settings.shared.secondaryLanguageEnabled
            && Settings.shared.secondaryHotkey.kind == .modifierOnly
        guard primaryDead || secondaryDead else { return }
        didWarnModifierHotkeyThisSession = true

        var dead: [String] = []
        if primaryDead { dead.append("“\(Settings.shared.hotkey.displayName)” (push-to-talk)") }
        if secondaryDead { dead.append("“\(Settings.shared.secondaryHotkey.displayName)” (language switch)") }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = primaryDead && secondaryDead
            ? "Your hotkeys need Accessibility access"
            : (primaryDead ? "Your push-to-talk key needs Accessibility access"
                           : "Your language-switch key needs Accessibility access")
        alert.informativeText = """
        \(dead.joined(separator: " and ")) \(dead.count == 1 ? "is a modifier-only hotkey" : "are modifier-only hotkeys"). \
        macOS only delivers those to apps trusted for Accessibility, so \(dead.count == 1 ? "it" : "they") won't \
        work until you grant access.

        Grant Dictly Accessibility access — or pick a regular key combination (e.g. ⌃⌥Space) \
        in Settings, which works without any permission.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsChecker.promptAccessibilityIfNeeded(reason: "modifier-hotkey")
            PermissionsChecker.openAccessibilitySettings()
        }
    }

    private func runTranscription(samples: [Float], language: String,
                                   fallbackCount: Int,
                                   pipelineStart: CFAbsoluteTime) async {
        do {
            let transcribeStart = CFAbsoluteTimeGetCurrent()
            guard let raw = try await transcriber.transcribe(samples: samples, language: language, fallbackCount: fallbackCount) else {
                Self.log.notice("Transcribe returned empty for \(samples.count) samples (lang=\(language))")
                phase.send(.error("No speech detected"))
                hud.show(state: .error("No speech detected"))
                hud.hideAfter(seconds: 1.9)
                phase.send(.idle)
                return
            }
            let transcribeSec = CFAbsoluteTimeGetCurrent() - transcribeStart
            Self.log.info("Transcribe ok: \(raw.count) chars")

            let postStart = CFAbsoluteTimeGetCurrent()
            let processed = (try? await postProcessor.process(raw, language: language)) ?? raw
            let postSec = CFAbsoluteTimeGetCurrent() - postStart

            let words = processed.split { $0.isWhitespace }.count
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName

            // Opt-in trailing space so push-to-talk phrases chain without typing
            // the separator by hand. Appended after post-processing (the post
            // processor trims edges) and only to non-empty text — an empty
            // transcript must never insert a lone space.
            let toInsert = Settings.shared.appendTrailingSpace && !processed.isEmpty
                ? processed + " " : processed

            let insertStart = CFAbsoluteTimeGetCurrent()
            let outcome = inserter.insert(toInsert)
            let insertSec = CFAbsoluteTimeGetCurrent() - insertStart

            let totalSec = CFAbsoluteTimeGetCurrent() - pipelineStart
            let audioSec = Double(samples.count) / AudioRecorder.targetSampleRate
            // Single-line summary at `.notice` so it shows in Xcode console and
            // Console.app by default (no need to enable "Info messages").
            Self.log.notice("pipeline: total=\(String(format: "%.2f", totalSec))s (transcribe=\(String(format: "%.2f", transcribeSec))s post=\(String(format: "%.2f", postSec))s insert=\(String(format: "%.2f", insertSec))s) for \(String(format: "%.2f", audioSec))s audio")

            var needsAccessibilityPrompt = false
            switch outcome {
            case .insertedAutomatically:
                phase.send(.inserted)
                hud.show(state: .inserted(words: words, app: frontApp))
                hud.hideAfter(seconds: 1.9)
            case .copiedToClipboard:
                phase.send(.inserted)
                hud.show(state: .copiedToClipboard)
                hud.hideAfter(seconds: 1.9)
            case .missingAccessibilityPermission:
                // Auto-paste was on but Accessibility isn't granted. The HUD flash
                // alone is too easy to miss (it vanished before the user could read
                // it), so keep it up longer AND surface a one-time actionable alert.
                phase.send(.inserted)
                hud.show(state: .needsAccessibility)
                hud.hideAfter(seconds: 5)
                needsAccessibilityPrompt = true
            }
            phase.send(.idle)
            // The alert is modal — send .idle first so the menu-bar icon isn't stuck
            // on the previous phase for as long as the alert stays up.
            if needsAccessibilityPrompt { promptAccessibilityOnce() }
        } catch {
            Self.log.error("Transcribe failed: \(error.localizedDescription)")
            phase.send(.error(error.localizedDescription))
            hud.show(state: .error(error.localizedDescription))
            hud.hideAfter(seconds: 1.5)
            phase.send(.idle)
        }
    }
}

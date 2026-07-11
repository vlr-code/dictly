import Foundation
import Combine

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    let didChange = PassthroughSubject<Void, Never>()

    private enum Keys {
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let hotkeyData = "hotkey.data.v1"
        static let hotkeyMode = "hotkey.mode"
        static let language = "transcription.language"
        static let secondaryLanguageEnabled = "transcription.language.secondary.enabled"
        static let secondaryLanguage = "transcription.language.secondary"
        static let secondaryLanguageActive = "transcription.language.secondary.active"
        static let secondaryHotkeyData = "hotkey.secondary.data.v1"
        static let modelID = "transcription.modelID"
        static let keepMicWarm = "audio.keepMicWarm"
        static let autoInsert = "behavior.autoInsert"
        static let appendTrailingSpace = "behavior.appendTrailingSpace"
        static let restoreClipboard = "behavior.restoreClipboard"
        static let showHUD = "behavior.showHUD"
        static let hudPosition = "behavior.hudPosition"
        static let llmCleanupEnabled = "postprocess.llm.enabled"
        static let transcriptionQuality = "transcription.quality"
    }

    enum HotkeyMode: String {
        case pushToTalk
        case toggle
    }

    /// Where the recording HUD pill appears on screen.
    enum HUDPosition: String, Sendable {
        /// Bottom-centre of the active screen, ~40 pt above the Dock.
        case bottom
        /// Top of the screen, anchored under the Dictly menu-bar icon. Useful if the
        /// user dictates into apps that have their own bottom controls (Slack, Notes).
        case top
    }

    /// How aggressively Whisper retries a chunk when its first decoding pass
    /// looks degenerate (high compression ratio, low avg logprob, etc.).
    /// Maps directly to `DecodingOptions.temperatureFallbackCount`.
    enum TranscriptionQuality: String, Sendable, CaseIterable {
        /// One greedy pass at temperature 0. Fastest. No recovery if Whisper
        /// gets stuck in a loop on noisy / Bluetooth-warmup audio.
        case fast
        /// Up to one retry at temperature 0.2 if the first pass looks bad.
        /// Default — costs ~1× extra transcribe time only when the recovery
        /// actually triggers, otherwise free.
        case balanced
        /// Up to three retries at progressively higher temperatures. More
        /// chances to escape a bad pass; pays the price (one extra full
        /// transcribe per retry) only when the audio was already going to
        /// produce garbage.
        case best

        /// Value forwarded to WhisperKit's decoder.
        var fallbackCount: Int {
            switch self {
            case .fast:     return 0
            case .balanced: return 1
            case .best:     return 3
            }
        }

        var displayName: String {
            switch self {
            case .fast:     return "Fast"
            case .balanced: return "Balanced"
            case .best:     return "Best quality"
            }
        }
    }

    var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: Keys.didCompleteOnboarding) }
        set { defaults.set(newValue, forKey: Keys.didCompleteOnboarding); didChange.send() }
    }

    var hotkey: KeyCombo {
        get {
            if let data = defaults.data(forKey: Keys.hotkeyData),
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                return combo
            }
            return .defaultHotkey
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.hotkeyData)
                didChange.send()
            }
        }
    }

    var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: Keys.hotkeyMode) ?? "") ?? .pushToTalk }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode); didChange.send() }
    }

    /// ISO 639-1 code, or "auto" for Whisper auto-detection.
    ///
    /// Default for a fresh install is the user's **system language** (if Whisper
    /// supports it), falling back to "auto". Previously this was hard-coded to
    /// "ru", which silently force-decoded every non-Russian user's speech as
    /// Russian — i.e. the app looked completely broken for them (GitHub #4).
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? Self.systemDefaultLanguage }
        set { defaults.set(newValue, forKey: Keys.language); didChange.send() }
    }

    /// The macOS preferred language mapped to a Whisper-supported ISO 639-1 code,
    /// or "auto" when none of the user's preferred languages is in our list.
    static let systemDefaultLanguage: String = {
        let supported = Set(LanguageOption.popular.map(\.code))
        for identifier in Locale.preferredLanguages {
            let code = String(identifier.prefix(2)).lowercased()
            if supported.contains(code) { return code }
        }
        return "auto"
    }()

    // MARK: Language switching (GitHub #1)
    //
    // A dedicated hotkey flips the *active* dictation language between two chosen
    // languages — `language` (primary) and `secondaryLanguage`. The active one is
    // used for every dictation and shown next to the menu-bar icon. Lets bilingual
    // users switch explicitly instead of relying on Whisper auto-detect, which
    // mis-guesses on short utterances.

    /// Master switch for the language-switch hotkey + menu-bar indicator. Off by default.
    var secondaryLanguageEnabled: Bool {
        get { defaults.bool(forKey: Keys.secondaryLanguageEnabled) }
        set { defaults.set(newValue, forKey: Keys.secondaryLanguageEnabled); didChange.send() }
    }

    /// The second of the two switchable languages. Defaults to English.
    var secondaryLanguage: String {
        get { defaults.string(forKey: Keys.secondaryLanguage) ?? "en" }
        set { defaults.set(newValue, forKey: Keys.secondaryLanguage); didChange.send() }
    }

    /// Whether the *second* language is currently the active one. Toggled by the
    /// switch hotkey; persisted so the choice survives relaunch.
    var secondaryLanguageActive: Bool {
        get { defaults.bool(forKey: Keys.secondaryLanguageActive) }
        set { defaults.set(newValue, forKey: Keys.secondaryLanguageActive); didChange.send() }
    }

    /// The language actually used for dictation right now: the second language
    /// when the switch is on *and* active, otherwise the primary `language`.
    var activeLanguage: String {
        (secondaryLanguageEnabled && secondaryLanguageActive) ? secondaryLanguage : language
    }

    /// Hotkey that flips the active language between the two. Defaults to right Option.
    var secondaryHotkey: KeyCombo {
        get {
            if let data = defaults.data(forKey: Keys.secondaryHotkeyData),
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                return combo
            }
            return KeyCombo(kind: .modifierOnly, solo: .rightOption, keyCode: nil, modifierFlags: 0)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.secondaryHotkeyData)
                didChange.send()
            }
        }
    }

    var modelID: String {
        get {
            var raw = defaults.string(forKey: Keys.modelID) ?? ModelInfo.defaultModelID
            // Migration 1: drop legacy `openai_whisper-` prefix WhisperKit prepends itself.
            if raw.hasPrefix("openai_whisper-") {
                raw = String(raw.dropFirst("openai_whisper-".count))
            }
            // Migration 2: turbo variants on HuggingFace use an underscore (not a hyphen)
            // before "turbo" — `openai_whisper-large-v3_turbo`. Older builds stored the
            // hyphen form which the glob never matched.
            raw = raw.replacingOccurrences(of: "-turbo", with: "_turbo")
            return raw
        }
        set { defaults.set(newValue, forKey: Keys.modelID); didChange.send() }
    }

    /// Keep the microphone stream open between dictations. Recording then starts
    /// instantly and includes up to half a second captured BEFORE the hotkey
    /// press, so mic-hardware wake-up (2–5 s cold on Apple Silicon) can't clip
    /// the first word. Costs the persistent macOS mic indicator; the recorder
    /// skips Bluetooth inputs (an open stream pins them to SCO call mode).
    var keepMicWarm: Bool {
        get { (defaults.object(forKey: Keys.keepMicWarm) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.keepMicWarm); didChange.send() }
    }

    var autoInsert: Bool {
        get { (defaults.object(forKey: Keys.autoInsert) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.autoInsert); didChange.send() }
    }

    /// Append a single space after each inserted phrase, so push-to-talk users
    /// can chain phrases without typing the separator themselves. Off by
    /// default: existing users keep the exact text they dictated.
    var appendTrailingSpace: Bool {
        get { defaults.bool(forKey: Keys.appendTrailingSpace) }
        set { defaults.set(newValue, forKey: Keys.appendTrailingSpace); didChange.send() }
    }

    var restoreClipboard: Bool {
        get { (defaults.object(forKey: Keys.restoreClipboard) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.restoreClipboard); didChange.send() }
    }

    var showHUD: Bool {
        get { (defaults.object(forKey: Keys.showHUD) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.showHUD); didChange.send() }
    }

    var hudPosition: HUDPosition {
        get { HUDPosition(rawValue: defaults.string(forKey: Keys.hudPosition) ?? "") ?? .bottom }
        set { defaults.set(newValue.rawValue, forKey: Keys.hudPosition); didChange.send() }
    }

    /// Reserved for iteration 2 (LLM cleanup).
    var llmCleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmCleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmCleanupEnabled); didChange.send() }
    }

    /// Trade-off between speed and quality of Whisper's decoding. See
    /// `TranscriptionQuality` for the per-preset semantics. Default is
    /// `.balanced` — one retry on degenerate output, otherwise zero cost.
    var transcriptionQuality: TranscriptionQuality {
        get { TranscriptionQuality(rawValue: defaults.string(forKey: Keys.transcriptionQuality) ?? "")
                ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: Keys.transcriptionQuality); didChange.send() }
    }
}

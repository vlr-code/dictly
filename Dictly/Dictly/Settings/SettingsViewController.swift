import AppKit
import Combine

/// All app settings on one window. Sections:
///   - Hotkey
///   - Language
///   - Transcription models  ← scrollable list, per-row download/delete/use
///   - Behaviour
///   - Permissions
@MainActor
final class SettingsViewController: NSViewController {

    private weak var coordinator: DictationCoordinator?
    private var subs = Set<AnyCancellable>()
    private var statusPollTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var lastAccessibilityGranted: Bool?

    // Width applied to all "form" controls in the right column of each row, so
    // every row is the same width regardless of whether the control inside is a
    // popup, a hotkey recorder, or anything else.
    private static let formControlWidth: CGFloat = 260

    // Hotkey / language / behaviour controls
    private let hotkeyControl: HotkeyRecorderControl
    private let modeButton = NSPopUpButton()
    private let languageButton = NSPopUpButton()
    private let secondaryLanguageCheck = NSButton(checkboxWithTitle: "Switch between two languages with a hotkey",
                                                  target: nil, action: nil)
    private let secondaryLanguageButton = NSPopUpButton()
    private let secondaryHotkeyControl: HotkeyRecorderControl
    private let qualityButton = NSPopUpButton()
    private let keepMicWarmCheck = NSButton(checkboxWithTitle: "Keep microphone warm for instant start",
                                            target: nil, action: nil)
    private let autoInsertCheck = NSButton(checkboxWithTitle: "Auto-paste into the focused app",
                                            target: nil, action: nil)
    private let appendSpaceCheck = NSButton(checkboxWithTitle: "Append a space after inserted text",
                                             target: nil, action: nil)
    private let restoreClipboardCheck = NSButton(checkboxWithTitle: "Restore clipboard after paste",
                                                  target: nil, action: nil)
    private let showHUDCheck = NSButton(checkboxWithTitle: "Show floating HUD while dictating",
                                         target: nil, action: nil)
    private let hudPositionButton = NSPopUpButton()

    private let microphoneStatus = NSTextField(labelWithString: "")
    private let microphoneButton = BrandButton(title: "Open Microphone",
                                                variant: .secondary, size: .sm)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let accessibilityButton = BrandButton(title: "Open Accessibility",
                                                   variant: .secondary, size: .sm)
    private let storeNoticeLabel = NSTextField(wrappingLabelWithString: "")

    // Models list
    private var modelRows: [String: ModelRowView] = [:]
    private let modelsScrollView = NSScrollView()
    private let modelsStack = NSStackView()
    private let modelsHelp = NSTextField(wrappingLabelWithString:
        "Tap Use to switch the active model. New models download automatically on first use.")
    private let reloadCatalogButton = NSButton()
    private let reloadSpinner = NSProgressIndicator()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.hotkeyControl = HotkeyRecorderControl(combo: Settings.shared.hotkey)
        self.secondaryHotkeyControl = HotkeyRecorderControl(combo: Settings.shared.secondaryHotkey)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 790))
        root.wantsLayer = true
        root.layer?.backgroundColor = DesignTokens.paper.cgColor
        view = root

        // Wrap the settings stack in a vertical NSScrollView so that the
        // window fits on small laptop displays. App Review flagged truncated
        // content on a 1280×800 reviewer screen — without this scroll the
        // bottom of the panel (Permissions, App Store notice) was unreachable.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        root.addSubview(scrollView)

        // `documentView` is the container the scroll view scrolls *over*.
        // Its width is locked to the visible content area so we never get
        // horizontal scrolling; height grows with the stack content.
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        documentView.addSubview(outer)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // Match document width to the scroll view's visible content width
            // (NSClipView). Outer stack then pins to documentView, so all
            // existing `widthAnchor.constraint(equalTo: outer.widthAnchor, …)`
            // constraints inside the body keep working without changes.
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            outer.topAnchor.constraint(equalTo: documentView.topAnchor),
            outer.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor)
        ])

        // Hotkey section
        outer.addArrangedSubview(sectionTitle("Hotkey"))
        outer.addArrangedSubview(makeRow(title: "Push-to-talk hotkey", control: hotkeyControl))
        outer.addArrangedSubview(makeRow(title: "Mode", control: modeButton))
        let modeHelp = NSTextField(wrappingLabelWithString:
            "Hold — record while the hotkey is pressed, release to transcribe. " +
            "Toggle — press once to start, again to stop.")
        modeHelp.font = NSFont.systemFont(ofSize: 11)
        modeHelp.textColor = DesignTokens.inkMute
        modeHelp.preferredMaxLayoutWidth = 540
        outer.addArrangedSubview(modeHelp)
        outer.addArrangedSubview(makeRow(title: "Spoken language", control: languageButton))
        outer.addArrangedSubview(secondaryLanguageCheck)
        outer.addArrangedSubview(makeRow(title: "Second language", control: secondaryLanguageButton))
        outer.addArrangedSubview(makeRow(title: "Switch-language hotkey", control: secondaryHotkeyControl))
        let secondaryHelp = NSTextField(wrappingLabelWithString:
            "Press this hotkey to flip the active language between your spoken " +
            "language above and the second language. The active one is used for " +
            "dictation and shown next to the menu-bar icon. A bare-modifier hotkey " +
            "(like the default right ⌥) needs Accessibility access to work.")
        secondaryHelp.font = NSFont.systemFont(ofSize: 11)
        secondaryHelp.textColor = DesignTokens.inkMute
        secondaryHelp.preferredMaxLayoutWidth = 540
        outer.addArrangedSubview(secondaryHelp)
        outer.addArrangedSubview(makeRow(title: "Quality", control: qualityButton))
        let qualityHelp = NSTextField(wrappingLabelWithString:
            "Whisper occasionally derails on noisy or Bluetooth audio and " +
            "produces gibberish (the classic “1, 2, 3, 1, 2, 3…” loop). When " +
            "that happens, it can re-run the failed chunk with a touch of " +
            "randomness to recover.\n\n" +
            "• Fast — one greedy pass, no recovery. Quickest, but a bad " +
            "capture stays bad.\n" +
            "• Balanced — one safety-net retry. Costs nothing on clean audio.\n" +
            "• Best quality — up to three retries with progressively more " +
            "randomness. Best chance to escape a degenerate decode; you only " +
            "pay extra time when the first pass was already going to fail.")
        qualityHelp.font = NSFont.systemFont(ofSize: 11)
        qualityHelp.textColor = DesignTokens.inkMute
        qualityHelp.preferredMaxLayoutWidth = 540
        outer.addArrangedSubview(qualityHelp)
        outer.addArrangedSubview(keepMicWarmCheck)
        let warmHelp = NSTextField(wrappingLabelWithString:
            "Keeps the microphone stream open between dictations, so recording " +
            "starts instantly and catches up to half a second before you press " +
            "the hotkey — first words are never clipped. macOS shows the " +
            "microphone indicator while Dictly runs. Bluetooth mics are excluded " +
            "(an open stream would pin them to low-quality call audio).")
        warmHelp.font = NSFont.systemFont(ofSize: 11)
        warmHelp.textColor = DesignTokens.inkMute
        warmHelp.preferredMaxLayoutWidth = 540
        outer.addArrangedSubview(warmHelp)
        outer.addArrangedSubview(divider())

        // Models section
        let modelsHeaderRow = makeModelsHeaderRow()
        outer.addArrangedSubview(modelsHeaderRow)
        modelsHeaderRow.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                                constant: -56).isActive = true
        modelsHelp.font = .systemFont(ofSize: 11)
        modelsHelp.textColor = DesignTokens.inkMute
        modelsHelp.preferredMaxLayoutWidth = 540
        outer.addArrangedSubview(modelsHelp)

        configureModelsList()

        // Wrap the scroll view inside a styled container. NSScrollView's own
        // backing layer is managed by AppKit (the clip view and scrollers are
        // its sublayers), so cornerRadius/border/backgroundColor set directly
        // on `modelsScrollView.layer` may be overridden or hidden. A plain
        // `NSView` container with `wantsLayer = true` is reliable.
        let modelsContainer = NSView()
        modelsContainer.translatesAutoresizingMaskIntoConstraints = false
        modelsContainer.wantsLayer = true
        modelsContainer.layer?.backgroundColor = DesignTokens.paperDeep.cgColor
        modelsContainer.layer?.cornerRadius = DesignTokens.radius
        modelsContainer.layer?.cornerCurve = .continuous
        modelsContainer.layer?.borderWidth = 1
        modelsContainer.layer?.borderColor = DesignTokens.paperBorder.cgColor
        modelsContainer.layer?.masksToBounds = true

        modelsContainer.addSubview(modelsScrollView)
        modelsScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Inset by 1pt so the scrollers / row content don't paint over the border.
            modelsScrollView.topAnchor.constraint(equalTo: modelsContainer.topAnchor, constant: 1),
            modelsScrollView.bottomAnchor.constraint(equalTo: modelsContainer.bottomAnchor, constant: -1),
            modelsScrollView.leadingAnchor.constraint(equalTo: modelsContainer.leadingAnchor, constant: 1),
            modelsScrollView.trailingAnchor.constraint(equalTo: modelsContainer.trailingAnchor, constant: -1),
        ])

        outer.addArrangedSubview(modelsContainer)
        modelsContainer.heightAnchor.constraint(equalToConstant: 320).isActive = true
        modelsContainer.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -56).isActive = true
        // Lock the inner stack to the scroll view's content width so each row stretches to the
        // visible scroll area instead of fading into empty space at the right edge.
        modelsStack.widthAnchor.constraint(equalTo: modelsScrollView.contentView.widthAnchor).isActive = true

        outer.addArrangedSubview(divider())

        // Behaviour section
        outer.addArrangedSubview(sectionTitle("Behaviour"))
        outer.addArrangedSubview(autoInsertCheck)
        outer.addArrangedSubview(appendSpaceCheck)
        outer.addArrangedSubview(restoreClipboardCheck)
        outer.addArrangedSubview(showHUDCheck)
        outer.addArrangedSubview(makeRow(title: "HUD position", control: hudPositionButton))

        outer.addArrangedSubview(divider())
        outer.addArrangedSubview(sectionTitle("Permissions"))

        // Both TCC permissions the app needs, so nobody has to reopen the
        // onboarding window just to check a status: mic (recording) and
        // Accessibility (auto-paste).
        outer.addArrangedSubview(permissionRow([microphoneStatus, microphoneButton]))
        outer.addArrangedSubview(permissionRow([accessibilityStatus, accessibilityButton]))

        storeNoticeLabel.font = NSFont.systemFont(ofSize: 11)
        storeNoticeLabel.textColor = DesignTokens.inkMute
        storeNoticeLabel.preferredMaxLayoutWidth = 540
        outer.addArrangedSubview(storeNoticeLabel)

        configureControls()
        styleCheckboxes()
        refreshFromSettings()
        refreshPermissionStatuses()
        bindCoordinator()
        bindCatalogService()
        refreshModelStates()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Poll while the settings window is visible so the indicators turn green as
        // soon as System Settings commits a permission change.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissionStatuses() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusPollTimer = timer

        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissionStatuses(forceLog: true) }
        }

        refreshPermissionStatuses(forceLog: true)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        statusPollTimer?.invalidate()
        statusPollTimer = nil
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func permissionRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        l.textColor = DesignTokens.inkMute
        return l
    }

    /// "TRANSCRIPTION MODELS" with a small reload button on the right edge that
    /// re-fetches the live catalog from HuggingFace. The caller is expected to
    /// install the row's width constraint *after* adding it to the outer
    /// stack — the row has no superview at construction time.
    private func makeModelsHeaderRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        row.addArrangedSubview(sectionTitle("Transcription models"))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        reloadSpinner.style = .spinning
        reloadSpinner.controlSize = .small
        reloadSpinner.isDisplayedWhenStopped = false
        reloadSpinner.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(reloadSpinner)

        reloadCatalogButton.image = NSImage(systemSymbolName: "arrow.clockwise",
                                             accessibilityDescription: "Reload model catalog")
        reloadCatalogButton.bezelStyle = .regularSquare
        reloadCatalogButton.isBordered = false
        reloadCatalogButton.contentTintColor = DesignTokens.inkMute
        reloadCatalogButton.toolTip = "Refresh model list from HuggingFace"
        reloadCatalogButton.target = self
        reloadCatalogButton.action = #selector(refreshCatalogTapped(_:))
        reloadCatalogButton.translatesAutoresizingMaskIntoConstraints = false
        reloadCatalogButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        reloadCatalogButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(reloadCatalogButton)

        return row
    }

    private func makeRow(title: String, control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.font = NSFont.systemFont(ofSize: 12)
        l.textColor = DesignTokens.ink
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 180).isActive = true
        // Pin every form control to the same width so each row aligns visually.
        // Without this, an `NSPopUpButton` only takes its intrinsic title width,
        // so the Mode/Language/HUD-position rows render narrower than the
        // composite Hotkey row.
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: Self.formControlWidth).isActive = true
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .custom
        b.fillColor = DesignTokens.paperBorder
        b.borderColor = .clear
        b.borderWidth = 0
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }

    private func styleCheckboxes() {
        for cb in [autoInsertCheck, appendSpaceCheck, restoreClipboardCheck, showHUDCheck] {
            cb.contentTintColor = DesignTokens.ink
        }
    }

    // MARK: - Models list

    private func configureModelsList() {
        modelsStack.orientation = .vertical
        modelsStack.alignment = .leading
        modelsStack.spacing = 10
        modelsStack.translatesAutoresizingMaskIntoConstraints = false
        // Horizontal insets match the inter-row spacing so the gutter on the
        // sides of each cell visually equals the gap between rows.
        modelsStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        // Rows are populated by `bindCatalogService()` once the live catalog
        // emits — see `rebuildModelRows(_:)`. Until then the bundled model is
        // the only entry (the service publishes it synchronously on init).
        rebuildModelRows(ModelCatalogService.shared.models.value)

        // Background, border and rounded corners live on a wrapper container
        // (see `loadView`). The scroll view itself is fully transparent.
        modelsScrollView.drawsBackground = false
        modelsScrollView.borderType = .noBorder
        modelsScrollView.hasVerticalScroller = true
        modelsScrollView.scrollerStyle = .overlay
        modelsScrollView.documentView = modelsStack
        modelsScrollView.contentView.postsBoundsChangedNotifications = false
        modelsScrollView.contentView.drawsBackground = false
    }

    /// Reconcile the visible row list with whatever the catalog service is
    /// currently publishing. Removes rows for IDs that disappeared, creates
    /// rows for new IDs, and re-orders the stack so the bundled row is first.
    private func rebuildModelRows(_ models: [ModelInfo]) {
        let newIDs = Set(models.map(\.id))

        // Remove any row whose model is no longer in the live catalog.
        for (id, row) in modelRows where !newIDs.contains(id) {
            modelsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            modelRows.removeValue(forKey: id)
        }

        // Strip arrangement so we can re-add in the new order.
        for view in modelsStack.arrangedSubviews {
            modelsStack.removeArrangedSubview(view)
        }

        let stackInsets = modelsStack.edgeInsets.left + modelsStack.edgeInsets.right
        for model in models {
            let row: ModelRowView
            let isNew: Bool
            if let existing = modelRows[model.id] {
                row = existing
                isNew = false
            } else {
                row = ModelRowView(model: model)
                row.onUse = { [weak self] in self?.useModel($0) }
                row.onDelete = { [weak self] in self?.deleteModel($0) }
                row.translatesAutoresizingMaskIntoConstraints = false
                modelRows[model.id] = row
                isNew = true
            }
            // Add to the stack first so the row and the stack share an ancestor;
            // only THEN install the width constraint that ties them together.
            // Activating it before `addArrangedSubview` raises
            // "no common ancestor" / NSGenericException.
            modelsStack.addArrangedSubview(row)
            if isNew {
                row.widthAnchor.constraint(equalTo: modelsStack.widthAnchor,
                                           constant: -stackInsets).isActive = true
            }
        }

        refreshModelStates()
    }

    private func refreshModelStates() {
        let active = Settings.shared.modelID
        for (id, row) in modelRows {
            let isBundled = ModelInfo.bundledIDs.contains(id)
            let isCached = ModelManager.isInCache(id)
            switch (id == active, isBundled, isCached) {
            case (true, true, _):       row.apply(.bundledActive)
            case (true, false, _):      row.apply(.active)
            case (false, true, _):      row.apply(.bundled)
            case (false, false, true):  row.apply(.downloaded)
            case (false, false, false): row.apply(.notDownloaded)
            }
        }
    }

    private func useModel(_ model: ModelInfo) {
        guard model.id != Settings.shared.modelID else { return }
        Settings.shared.modelID = model.id
        // If the model is already on disk we're not downloading anything — just loading
        // it into memory. Show a quieter "Loading…" state so the UI doesn't lie about
        // bytes being transferred.
        let alreadyLocal = ModelInfo.bundledIDs.contains(model.id) || ModelManager.isInCache(model.id)
        modelRows[model.id]?.apply(alreadyLocal
                                   ? .preparing(progress: 0)
                                   : .downloading(progress: 0))
        Task { await coordinator?.prepareModelInBackground() }
    }

    private func deleteModel(_ model: ModelInfo) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.displayName)?"
        if let mb = model.approximateSizeMB {
            alert.informativeText = "This frees ~\(mb) MB. The model can be re-downloaded later."
        } else {
            alert.informativeText = "The model can be re-downloaded later."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            try? ModelManager.delete(model.id)
            refreshModelStates()
        }
    }

    @objc private func refreshCatalogTapped(_ sender: Any?) {
        ModelCatalogService.shared.refresh()
    }

    // MARK: - Other controls

    private func configureControls() {
        modeButton.removeAllItems()
        modeButton.addItems(withTitles: ["Hold (push-to-talk)", "Toggle"])
        modeButton.target = self
        modeButton.action = #selector(modeChanged(_:))
        modeButton.toolTip =
            "Hold — press and hold the hotkey to record, release to stop and transcribe.\n" +
            "Toggle — press once to start recording, press again to stop and transcribe."

        languageButton.removeAllItems()
        for opt in LanguageOption.popular {
            languageButton.addItem(withTitle: opt.displayName)
            languageButton.lastItem?.representedObject = opt.code
        }
        languageButton.target = self
        languageButton.action = #selector(languageChanged(_:))

        secondaryLanguageButton.removeAllItems()
        for opt in LanguageOption.popular {
            secondaryLanguageButton.addItem(withTitle: opt.displayName)
            secondaryLanguageButton.lastItem?.representedObject = opt.code
        }
        secondaryLanguageButton.target = self
        secondaryLanguageButton.action = #selector(secondaryLanguageChanged(_:))
        secondaryLanguageCheck.target = self
        secondaryLanguageCheck.action = #selector(secondaryLanguageToggled(_:))
        secondaryHotkeyControl.onChange = { [weak self] combo in
            guard let self else { return }
            // The two hotkeys must differ: with one key on both, every dictation
            // press would also flip the language (both monitors see the same event).
            guard combo != Settings.shared.hotkey else {
                self.secondaryHotkeyControl.combo = Settings.shared.secondaryHotkey
                self.showDuplicateHotkeyAlert()
                return
            }
            Settings.shared.secondaryHotkey = combo
            self.coordinator?.secondaryHotkey.update(combo: combo)
        }

        keepMicWarmCheck.target = self
        keepMicWarmCheck.action = #selector(keepMicWarmChanged(_:))
        autoInsertCheck.target = self
        autoInsertCheck.action = #selector(autoInsertChanged(_:))
        appendSpaceCheck.target = self
        appendSpaceCheck.action = #selector(appendSpaceChanged(_:))
        restoreClipboardCheck.target = self
        restoreClipboardCheck.action = #selector(restoreClipboardChanged(_:))
        showHUDCheck.target = self
        showHUDCheck.action = #selector(showHUDChanged(_:))

        hudPositionButton.removeAllItems()
        hudPositionButton.addItem(withTitle: "Bottom of screen")
        hudPositionButton.lastItem?.representedObject = Settings.HUDPosition.bottom.rawValue
        hudPositionButton.addItem(withTitle: "Top — under Dictly icon")
        hudPositionButton.lastItem?.representedObject = Settings.HUDPosition.top.rawValue
        hudPositionButton.target = self
        hudPositionButton.action = #selector(hudPositionChanged(_:))

        qualityButton.removeAllItems()
        for q in Settings.TranscriptionQuality.allCases {
            qualityButton.addItem(withTitle: q.displayName)
            qualityButton.lastItem?.representedObject = q.rawValue
        }
        qualityButton.target = self
        qualityButton.action = #selector(qualityChanged(_:))

        microphoneButton.target = self
        microphoneButton.action = #selector(microphoneButtonTapped(_:))
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility(_:))

        hotkeyControl.onChange = { [weak self] combo in
            guard let self else { return }
            // Mirror of the secondary-hotkey guard: the two must stay distinct.
            guard !(Settings.shared.secondaryLanguageEnabled
                    && combo == Settings.shared.secondaryHotkey) else {
                self.hotkeyControl.combo = Settings.shared.hotkey
                self.showDuplicateHotkeyAlert()
                return
            }
            Settings.shared.hotkey = combo
            self.coordinator?.hotkey.update(combo: combo)
        }
    }

    private func bindCoordinator() {
        coordinator?.phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                let activeID = Settings.shared.modelID
                switch phase {
                case .modelLoading(let p):
                    if let row = self.modelRows[activeID] {
                        let isLocal = ModelInfo.bundledIDs.contains(activeID)
                            || ModelManager.isInCache(activeID)
                        row.apply(isLocal ? .preparing(progress: p) : .downloading(progress: p))
                    }
                case .idle:
                    if self.coordinator?.isModelReady == true {
                        self.refreshModelStates()
                    }
                case .error:
                    self.refreshModelStates()
                default: break
                }
            }
            .store(in: &subs)
    }

    /// Subscribe to the live HuggingFace-backed model catalog. We rebuild the
    /// row list every time the catalog publishes a new snapshot, and reflect
    /// loading / error state on the section header.
    private func bindCatalogService() {
        let svc = ModelCatalogService.shared
        svc.models
            .receive(on: RunLoop.main)
            .sink { [weak self] models in
                self?.rebuildModelRows(models)
            }
            .store(in: &subs)
        svc.isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in
                guard let self else { return }
                if loading {
                    self.reloadCatalogButton.isHidden = true
                    self.reloadSpinner.startAnimation(nil)
                } else {
                    self.reloadSpinner.stopAnimation(nil)
                    self.reloadCatalogButton.isHidden = false
                }
            }
            .store(in: &subs)
        svc.lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] err in
                guard let self else { return }
                if let err {
                    self.modelsHelp.stringValue =
                        "Couldn't refresh model list: \(err). Tap ⟳ to retry."
                } else {
                    self.modelsHelp.stringValue =
                        "Tap Use to switch the active model. New models download automatically on first use."
                }
            }
            .store(in: &subs)
    }

    private func refreshFromSettings() {
        modeButton.selectItem(at: Settings.shared.hotkeyMode == .pushToTalk ? 0 : 1)

        let lang = Settings.shared.language
        if let idx = LanguageOption.popular.firstIndex(where: { $0.code == lang }) {
            languageButton.selectItem(at: idx)
        }

        secondaryLanguageCheck.state = Settings.shared.secondaryLanguageEnabled ? .on : .off
        let lang2 = Settings.shared.secondaryLanguage
        if let idx = LanguageOption.popular.firstIndex(where: { $0.code == lang2 }) {
            secondaryLanguageButton.selectItem(at: idx)
        }
        secondaryHotkeyControl.combo = Settings.shared.secondaryHotkey
        updateSecondaryControlsEnabled()

        keepMicWarmCheck.state = Settings.shared.keepMicWarm ? .on : .off
        autoInsertCheck.state = Settings.shared.autoInsert ? .on : .off
        appendSpaceCheck.state = Settings.shared.appendTrailingSpace ? .on : .off
        restoreClipboardCheck.state = Settings.shared.restoreClipboard ? .on : .off
        showHUDCheck.state = Settings.shared.showHUD ? .on : .off

        let pos = Settings.shared.hudPosition
        hudPositionButton.selectItem(at: pos == .bottom ? 0 : 1)

        let quality = Settings.shared.transcriptionQuality
        if let idx = Settings.TranscriptionQuality.allCases.firstIndex(of: quality) {
            qualityButton.selectItem(at: idx)
        }

        storeNoticeLabel.stringValue = "Auto-paste needs Accessibility access for this exact Dictly.app. If it stays red after granting access, remove Dictly from Accessibility and add /Applications/Dictly.app again."
    }

    private func refreshPermissionStatuses(forceLog: Bool = false) {
        refreshMicrophoneStatus()
        refreshAccessibilityStatus(forceLog: forceLog)
    }

    private func refreshMicrophoneStatus() {
        let text: String, color: NSColor, buttonTitle: String
        switch PermissionsChecker.microphoneStatus {
        case .authorized:
            (text, color, buttonTitle) = ("Microphone granted", DesignTokens.goodInk, "Open Microphone")
        case .denied:
            (text, color, buttonTitle) = ("Microphone not granted", DesignTokens.danger, "Open Microphone")
        case .notDetermined:
            (text, color, buttonTitle) = ("Microphone not requested yet", DesignTokens.inkMute, "Allow Microphone")
        }
        microphoneStatus.stringValue = text
        microphoneStatus.textColor = color
        microphoneStatus.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        // BrandButton's title setter re-derives styling and its width constraint —
        // skip no-op assignments so the 1 s permission poll doesn't churn layout.
        if microphoneButton.title != buttonTitle { microphoneButton.title = buttonTitle }
    }

    private func refreshAccessibilityStatus(forceLog: Bool = false) {
        let granted = PermissionsChecker.isAccessibilityGranted
        if forceLog || lastAccessibilityGranted != granted {
            AppLogger(category: "Permissions").info("Accessibility status refreshed; granted=\(granted) bundlePath=\(Bundle.main.bundleURL.path)")
            lastAccessibilityGranted = granted
        }
        accessibilityStatus.stringValue = granted
            ? "Accessibility granted"
            : "Accessibility not granted"
        accessibilityStatus.textColor = granted ? DesignTokens.goodInk : DesignTokens.danger
        accessibilityStatus.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        Settings.shared.hotkeyMode = sender.indexOfSelectedItem == 0 ? .pushToTalk : .toggle
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            Settings.shared.language = code
        }
    }

    @objc private func secondaryLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            Settings.shared.secondaryLanguage = code
        }
    }

    @objc private func secondaryLanguageToggled(_ sender: NSButton) {
        // Refuse to enable while both hotkeys share one combo (possible when the
        // secondary was recorded earlier, while the feature was off).
        if sender.state == .on, Settings.shared.secondaryHotkey == Settings.shared.hotkey {
            sender.state = .off
            showDuplicateHotkeyAlert()
            return
        }
        Settings.shared.secondaryLanguageEnabled = sender.state == .on
        updateSecondaryControlsEnabled()
    }

    /// Both hotkey recorders and the enable checkbox funnel here when a change
    /// would leave the push-to-talk and switch-language hotkeys on one key; the
    /// caller has already reverted the change.
    private func showDuplicateHotkeyAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "That key is already taken"
        alert.informativeText = "The push-to-talk hotkey and the switch-language hotkey must be different keys."
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The second-language popup and hotkey recorder only matter when the
    /// feature is on; dim them otherwise. (HotkeyRecorderControl is a plain
    /// NSView, so we dim via alpha rather than `isEnabled`.)
    private func updateSecondaryControlsEnabled() {
        let on = Settings.shared.secondaryLanguageEnabled
        secondaryLanguageButton.isEnabled = on
        secondaryHotkeyControl.alphaValue = on ? 1.0 : 0.5
    }

    @objc private func keepMicWarmChanged(_ sender: NSButton) {
        Settings.shared.keepMicWarm = sender.state == .on
    }

    @objc private func autoInsertChanged(_ sender: NSButton) {
        Settings.shared.autoInsert = sender.state == .on
    }

    @objc private func appendSpaceChanged(_ sender: NSButton) {
        Settings.shared.appendTrailingSpace = sender.state == .on
    }

    @objc private func restoreClipboardChanged(_ sender: NSButton) {
        Settings.shared.restoreClipboard = sender.state == .on
    }

    @objc private func showHUDChanged(_ sender: NSButton) {
        Settings.shared.showHUD = sender.state == .on
    }

    @objc private func hudPositionChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String,
           let pos = Settings.HUDPosition(rawValue: raw) {
            Settings.shared.hudPosition = pos
        }
    }

    @objc private func qualityChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String,
           let q = Settings.TranscriptionQuality(rawValue: raw) {
            Settings.shared.transcriptionQuality = q
        }
    }

    @objc private func microphoneButtonTapped(_ sender: Any?) {
        // Not asked yet → fire the system prompt right here; once answered, the
        // only place to change it is System Settings → Privacy → Microphone.
        if PermissionsChecker.microphoneStatus == .notDetermined {
            Task { @MainActor [weak self] in
                _ = await PermissionsChecker.requestMicrophone()
                self?.refreshMicrophoneStatus()
            }
        } else {
            PermissionsChecker.openMicrophoneSettings()
        }
    }

    @objc private func openAccessibility(_ sender: Any?) {
        PermissionsChecker.promptAccessibilityIfNeeded(reason: "settings-button")
        PermissionsChecker.openAccessibilitySettings()
        for delay in [0.5, 1.5, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAccessibilityStatus(forceLog: true)
            }
        }
    }

}

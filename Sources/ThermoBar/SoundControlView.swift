import AppKit

final class SoundControlView: NSView {
    static let preferredSize = NSSize(width: 360, height: 276)
    private static let rowsOriginY: CGFloat = 145
    let typingFeedbackView = TypingFeedbackView(frame: NSRect(x: 12, y: 61, width: 336, height: 76))
    private static let rowHeight: CGFloat = 55

    var onVolumeChange: ((Float, pid_t) -> Void)?
    var onOutputChange: ((String?, pid_t) -> Void)?
    var onDeviceVolumeChange: ((Float, String) -> Void)?
    var onMasterPlaybackToggle: (() -> Void)?
    var onPlaybackToggle: ((String) -> Void)?
    var onPermanentChange: ((SoundPermanentMedia, Bool) -> Void)?
    var onPermanentMove: ((String, Int) -> Void)?
    var onContentHeightChange: (() -> Void)?
    var onSaveScene: ((String) -> Void)?
    var onApplyScene: ((String) -> Void)?
    var savedSceneNames: (() -> [String])?

    var minimumContentHeight: CGFloat {
        max(
            Self.preferredSize.height,
            Self.rowsOriginY + CGFloat(snapshot.apps.count) * Self.rowHeight
        )
    }

    private let statusLabel = NSTextField(labelWithString: "Looking for active audio…")
    private let manageMediaButton = SoundHoverButton(title: "+", target: nil, action: nil)
    private let scenesButton = SoundHoverButton(title: "Scenes", target: nil, action: nil)
    private let masterVolumeView = SoundMasterVolumeView()
    private let rowsContainer = SoundRowsContainerView()
    private var rows: [SoundAppRowView] = []
    private var snapshot = SoundControlSnapshot()
    private weak var outputPicker: SoundOutputPickerView?
    private weak var permanentMediaManager: SoundPermanentMediaManagerView?
    private var outputPickerDismissWorkItem: DispatchWorkItem?
    private weak var typingSoundPicker: TypingSoundPickerView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(_ snapshot: SoundControlSnapshot) {
        self.snapshot = snapshot
        statusLabel.stringValue = snapshot.message
        let masterApp = snapshot.apps.first(where: { $0.playbackState == .playing })
            ?? snapshot.apps.first(where: { $0.playbackState.isTransitioning })
            ?? snapshot.apps.first(where: { $0.bundleIdentifier != nil })
        masterVolumeView.configure(
            device: snapshot.devices.first(where: \.isDefault),
            playbackState: masterApp?.playbackState,
            targetName: masterApp?.name
        )
        permanentMediaManager?.configure(
            candidates: snapshot.permanentCandidates,
            permanent: snapshot.permanentMedia
        )
        let currentIdentifiers = rows.map(\.representedIdentifier)
        let nextIdentifiers = snapshot.apps.map(\.stableIdentifier)
        if !rows.isEmpty, currentIdentifiers == nextIdentifiers {
            for (row, app) in zip(rows, snapshot.apps) {
                row.configure(app: app, devices: snapshot.devices)
            }
        } else {
            rebuildRows()
        }
    }

    private func configure() {
        statusLabel.font = .systemFont(ofSize: 9.0, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 14, y: 7, width: bounds.width - 112, height: 13)
        statusLabel.autoresizingMask = [.width]
        addSubview(statusLabel)

        manageMediaButton.frame = NSRect(x: bounds.width - 30, y: 3, width: 19, height: 19)
        manageMediaButton.autoresizingMask = [.minXMargin]
        manageMediaButton.title = ""
        manageMediaButton.isBordered = false
        manageMediaButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Manage permanent media")
        manageMediaButton.imagePosition = .imageOnly
        manageMediaButton.contentTintColor = .secondaryLabelColor
        manageMediaButton.target = self
        manageMediaButton.action = #selector(togglePermanentMediaManager)
        manageMediaButton.toolTip = "Manage permanent media"
        manageMediaButton.setAccessibilityLabel("Manage permanent media")
        addSubview(manageMediaButton)
        scenesButton.frame = NSRect(x: bounds.width - 90, y: 3, width: 55, height: 19)
        scenesButton.autoresizingMask = [.minXMargin]
        scenesButton.font = .systemFont(ofSize: 9, weight: .medium)
        scenesButton.isBordered = false
        scenesButton.target = self
        scenesButton.action = #selector(showScenes)
        scenesButton.toolTip = "Save or apply app volumes, outputs, and pinned media"
        addSubview(scenesButton)

        masterVolumeView.frame = NSRect(x: 12, y: 24, width: bounds.width - 24, height: 32)
        masterVolumeView.autoresizingMask = [.width]
        masterVolumeView.onVolumeChange = { [weak self] volume, uid in
            self?.onDeviceVolumeChange?(volume, uid)
        }
        masterVolumeView.onPlaybackToggle = { [weak self] in self?.onMasterPlaybackToggle?() }
        addSubview(masterVolumeView)
        addSubview(typingFeedbackView)
        typingFeedbackView.onChooseSound = { [weak self] in self?.toggleTypingSoundPicker() }

        rowsContainer.frame = NSRect(
            x: 0,
            y: Self.rowsOriginY,
            width: bounds.width,
            height: max(0, bounds.height - Self.rowsOriginY)
        )
        rowsContainer.autoresizingMask = [.width]
        addSubview(rowsContainer)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sound controls")
    }

    override func layout() {
        super.layout()
        rowsContainer.frame = NSRect(
            x: 0,
            y: Self.rowsOriginY,
            width: bounds.width,
            height: max(
                0,
                bounds.height - Self.rowsOriginY,
                CGFloat(snapshot.apps.count) * Self.rowHeight
            )
        )
    }
    private func toggleTypingSoundPicker() {
        if let typingSoundPicker { typingSoundPicker.removeFromSuperview(); self.typingSoundPicker = nil; return }
        let choices = TypingSoundPickerView(selected: typingFeedbackView.selectedSound)
        let anchor = typingFeedbackView.convert(typingFeedbackView.soundPickerAnchor, to: self)
        choices.frame.origin = NSPoint(x: anchor.minX, y: anchor.maxY)
        choices.onSelection = { [weak self, weak choices] name in
            choices?.removeFromSuperview(); self?.typingSoundPicker = nil
            self?.typingFeedbackView.chooseSound(name)
        }
        addSubview(choices, positioned: .above, relativeTo: nil)
        typingSoundPicker = choices
    }
    func dismissTypingSoundPicker() {
        typingSoundPicker?.removeFromSuperview(); typingSoundPicker = nil
    }

    @objc private func showScenes() {
        let menu = NSMenu()
        let saved = savedSceneNames?() ?? []
        for name in saved {
            let item = NSMenuItem(title: "Apply \(name)", action: #selector(applyScene(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        if !saved.isEmpty { menu.addItem(.separator()) }
        let save = NSMenuItem(title: "Save current settings as…", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for name in ["Gaming", "Study", "Speakers", "Headphones"] {
            let item = NSMenuItem(title: saved.contains(name) ? "Replace \(name)" : name,
                                  action: #selector(saveScene(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            choices.addItem(item)
        }
        save.submenu = choices
        menu.addItem(save)
        menu.popUp(positioning: nil, at: NSPoint(x: scenesButton.frame.minX, y: scenesButton.frame.maxY), in: self)
    }

    @objc private func saveScene(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onSaveScene?(name) }
    }

    @objc private func applyScene(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onApplyScene?(name) }
    }

    private func rebuildRows() {
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        outputPickerDismissWorkItem?.cancel()
        outputPickerDismissWorkItem = nil
        outputPicker = nil

        if snapshot.apps.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Start music, a video, or a game to show its audio controls here.")
            empty.font = .systemFont(ofSize: 10)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: 36, y: 38, width: bounds.width - 72, height: 36)
            empty.autoresizingMask = [.width]
            rowsContainer.addSubview(empty)
            onContentHeightChange?()
            return
        }

        rowsContainer.frame.size.height = max(
            bounds.height - Self.rowsOriginY,
            CGFloat(snapshot.apps.count) * Self.rowHeight
        )
        for (index, app) in snapshot.apps.enumerated() {
            let row = SoundAppRowView(frame: NSRect(
                x: 12,
                y: CGFloat(index) * Self.rowHeight,
                width: bounds.width - 24,
                height: Self.rowHeight
            ))
            row.autoresizingMask = [.width]
            row.configure(app: app, devices: snapshot.devices)
            row.onVolumeChange = { [weak self] volume, pid in self?.onVolumeChange?(volume, pid) }
            row.onOutputChange = { [weak self] uid, pid in self?.onOutputChange?(uid, pid) }
            row.onDeviceVolumeChange = { [weak self] volume, uid in self?.onDeviceVolumeChange?(volume, uid) }
            row.onPlaybackToggle = { [weak self] identifier in self?.onPlaybackToggle?(identifier) }
            row.onOutputPickerHoverChange = { [weak self, weak row] hovering, pid, selectedUID, devices in
                guard let self, let row else { return }
                if hovering {
                    self.showOutputPicker(for: row, pid: pid, selectedUID: selectedUID, devices: devices)
                } else {
                    self.scheduleOutputPickerDismiss(for: pid)
                }
            }
            rowsContainer.addSubview(row)
            rows.append(row)
        }
        onContentHeightChange?()
    }

    @objc private func togglePermanentMediaManager() {
        if let permanentMediaManager {
            permanentMediaManager.removeFromSuperview()
            self.permanentMediaManager = nil
            return
        }

        let manager = SoundPermanentMediaManagerView(
            candidates: snapshot.permanentCandidates,
            permanent: snapshot.permanentMedia
        )
        manager.onPermanentChange = { [weak self] media, enabled in
            self?.onPermanentChange?(media, enabled)
        }
        manager.onMove = { [weak self] identifier, direction in
            self?.onPermanentMove?(identifier, direction)
        }
        let width: CGFloat = 252
        let height = min(CGFloat(164), manager.preferredHeight)
        manager.frame = NSRect(x: bounds.width - width - 8, y: 28, width: width, height: height)
        manager.autoresizingMask = [.minXMargin]
        addSubview(manager, positioned: .above, relativeTo: nil)
        permanentMediaManager = manager
    }

    private func showOutputPicker(
        for row: SoundAppRowView,
        pid: pid_t,
        selectedUID: String?,
        devices: [SoundOutputDevice]
    ) {
        outputPickerDismissWorkItem?.cancel()
        outputPickerDismissWorkItem = nil
        if outputPicker?.representedPID == pid { return }
        outputPicker?.removeFromSuperview()

        let picker = SoundOutputPickerView(pid: pid, selectedUID: selectedUID, devices: devices)
        picker.onSelection = { [weak self, weak row, weak picker] uid in
            row?.showSelectedOutput(uid: uid, devices: devices)
            self?.onOutputChange?(uid, pid)
            picker?.removeFromSuperview()
            self?.outputPicker = nil
        }
        picker.onHoverChange = { [weak self] hovering in
            if hovering {
                self?.outputPickerDismissWorkItem?.cancel()
                self?.outputPickerDismissWorkItem = nil
            } else {
                self?.scheduleOutputPickerDismiss(for: pid)
            }
        }
        let anchor = row.outputAnchorRect(in: rowsContainer)
        let width: CGFloat = 174
        let height = picker.preferredHeight
        let x = min(max(8, anchor.maxX - width), rowsContainer.bounds.width - width - 8)
        var y = anchor.maxY + 3
        if y + height > rowsContainer.bounds.height {
            y = max(3, anchor.minY - height - 3)
        }
        picker.frame = NSRect(x: x, y: y, width: width, height: height)
        rowsContainer.addSubview(picker, positioned: .above, relativeTo: nil)
        outputPicker = picker
    }

    private func scheduleOutputPickerDismiss(for pid: pid_t) {
        outputPickerDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.outputPicker?.representedPID == pid else { return }
            self.outputPicker?.removeFromSuperview()
            self.outputPicker = nil
            self.outputPickerDismissWorkItem = nil
        }
        outputPickerDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }
}

private final class SoundRowsContainerView: NSView {
    override var isFlipped: Bool { true }
}

private final class SoundMasterVolumeView: SoundHoverCardView {
    var onVolumeChange: ((Float, String) -> Void)?
    var onPlaybackToggle: (() -> Void)?

    private let playbackButton = SoundHoverButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "MASTER")
    private let outputLabel = NSTextField(labelWithString: "No output")
    private let slider = SoundHoverSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let percentLabel = NSTextField(labelWithString: "—")
    private var deviceUID: String?
    private var playbackState: SoundPlaybackState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playbackButton.isBordered = false
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackButton.toolTip = "Play or pause the most recently started media"
        playbackButton.setAccessibilityLabel("Master play or pause")
        addSubview(playbackButton)

        titleLabel.font = .systemFont(ofSize: 8.5, weight: .bold)
        addSubview(titleLabel)
        outputLabel.font = .systemFont(ofSize: 7.2)
        outputLabel.textColor = .tertiaryLabelColor
        outputLabel.lineBreakMode = .byTruncatingTail
        addSubview(outputLabel)

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeChanged)
        slider.setAccessibilityLabel("Master volume")
        addSubview(slider)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        percentLabel.alignment = .right
        addSubview(percentLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playbackButton.frame = NSRect(x: 5, y: 4, width: 24, height: 24)
        titleLabel.frame = NSRect(x: 34, y: 4, width: 54, height: 12)
        outputLabel.frame = NSRect(x: 34, y: 16, width: 79, height: 11)
        slider.frame = NSRect(x: 119, y: 6, width: bounds.width - 167, height: 20)
        percentLabel.frame = NSRect(x: bounds.width - 43, y: 9, width: 35, height: 14)
    }

    func configure(device: SoundOutputDevice?, playbackState: SoundPlaybackState?, targetName: String?) {
        deviceUID = device?.uid
        self.playbackState = playbackState
        let transitioning = playbackState?.isTransitioning == true
        let presentsAsPlaying = playbackState?.presentsAsPlaying == true
        let actionName = presentsAsPlaying ? "Pause" : "Play"
        let target = targetName ?? "media"
        playbackButton.image = NSImage(
            systemSymbolName: presentsAsPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: "\(actionName) \(target)"
        )
        playbackButton.isEnabled = playbackState != nil && !transitioning
        playbackButton.alphaValue = playbackState == nil ? 0.28 : transitioning ? 0.55 : 1
        playbackButton.toolTip = transitioning
            ? (playbackState == .starting ? "Starting \(target)…" : "Pausing \(target)…")
            : "\(actionName) \(target)"
        playbackButton.setAccessibilityLabel("Master: \(actionName) \(target)")
        outputLabel.stringValue = device?.name ?? "No output"
        outputLabel.toolTip = device?.silenceWarning ?? device?.name
        guard let volume = device?.volume else {
            slider.isEnabled = false
            percentLabel.stringValue = "—"
            slider.toolTip = "The current output does not support software volume control"
            return
        }
        slider.isEnabled = true
        if slider.cell?.isHighlighted != true { slider.floatValue = volume }
        let percent = Int((volume * 100).rounded())
        percentLabel.stringValue = device?.isMuted == true ? "Muted" : "\(percent)%"
        slider.toolTip = device?.isMuted == true
            ? "Output is muted. Adjust volume to unmute."
            : "Master volume: \(percent)%"
    }

    @objc private func togglePlayback() {
        guard playbackState?.isTransitioning != true else { return }
        onPlaybackToggle?()
    }

    @objc private func volumeChanged() {
        guard let deviceUID else { return }
        let percent = Int((slider.floatValue * 100).rounded())
        percentLabel.stringValue = "\(percent)%"
        slider.toolTip = "Master volume: \(percent)%"
        onVolumeChange?(slider.floatValue, deviceUID)
    }
}

private class SoundHoverCardView: NSView {
    private var trackingAreaReference: NSTrackingArea?
    private(set) var isHovered = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        updateHoverAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverAppearance()
    }

    private func updateHoverAppearance() {
        layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.055).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = 0
    }
}

private final class SoundHoverSlider: NSSlider {
    private var trackingAreaReference: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class SoundHoverButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingAreaReference: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        onHoverChange?(false)
    }
}

private final class SoundAppRowView: SoundHoverCardView {
    var onVolumeChange: ((Float, pid_t) -> Void)?
    var onOutputChange: ((String?, pid_t) -> Void)?
    var onDeviceVolumeChange: ((Float, String) -> Void)?
    var onPlaybackToggle: ((String) -> Void)?
    var onOutputPickerHoverChange: ((Bool, pid_t, String?, [SoundOutputDevice]) -> Void)?

    private let iconView = NSImageView()
    private let playbackButton = SoundHoverButton(title: "", target: nil, action: nil)
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let slider = SoundHoverSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let appVolumeLabel = NSTextField(labelWithString: "APP")
    private let outputButton = SoundHoverButton(title: "System Output", target: nil, action: nil)
    private let deviceVolumeLabel = NSTextField(labelWithString: "DEV")
    private let deviceVolumeSlider = SoundHoverSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var pid: pid_t = 0
    private var deviceSignature: [String] = []
    private var devices: [SoundOutputDevice] = []
    private var configuredOutputUID: String?
    private var rowIdentifier = ""
    private var appIsActive = false

    var representedPID: pid_t { pid }
    var representedIdentifier: String { rowIdentifier }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        playbackButton.isBordered = false
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackButton.setAccessibilityLabel("Play or pause media")
        addSubview(playbackButton)
        nameLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        detailLabel.font = .systemFont(ofSize: 7.8)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeChanged)
        slider.setAccessibilityLabel("App volume")
        addSubview(slider)

        appVolumeLabel.font = .systemFont(ofSize: 7, weight: .semibold)
        appVolumeLabel.textColor = .tertiaryLabelColor
        addSubview(appVolumeLabel)

        outputButton.controlSize = .small
        outputButton.bezelStyle = .rounded
        outputButton.font = .systemFont(ofSize: 8.5, weight: .medium)
        outputButton.imagePosition = .imageLeading
        outputButton.target = self
        outputButton.action = #selector(showOutputPicker)
        outputButton.onHoverChange = { [weak self] hovering in
            guard let self else { return }
            self.onOutputPickerHoverChange?(hovering, self.pid, self.configuredOutputUID, self.devices)
        }
        outputButton.setAccessibilityLabel("Choose app audio output")
        addSubview(outputButton)

        deviceVolumeLabel.font = .systemFont(ofSize: 7, weight: .semibold)
        deviceVolumeLabel.textColor = .tertiaryLabelColor
        addSubview(deviceVolumeLabel)

        deviceVolumeSlider.controlSize = .mini
        deviceVolumeSlider.isContinuous = true
        deviceVolumeSlider.target = self
        deviceVolumeSlider.action = #selector(deviceVolumeChanged)
        deviceVolumeSlider.setAccessibilityLabel("Output device volume")
        addSubview(deviceVolumeSlider)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 5, y: 15, width: 24, height: 24)
        playbackButton.frame = NSRect(x: 33, y: 17, width: 20, height: 20)
        nameLabel.frame = NSRect(x: 58, y: 9, width: appIsActive ? 84 : bounds.width - 70, height: 14)
        detailLabel.frame = NSRect(x: 58, y: 29, width: appIsActive ? 84 : bounds.width - 70, height: 12)
        slider.frame = NSRect(x: 145, y: 12, width: 82, height: 20)
        appVolumeLabel.frame = NSRect(x: 148, y: 37, width: 79, height: 11)
        outputButton.frame = NSRect(x: 233, y: 6, width: bounds.width - 240, height: 24)
        deviceVolumeLabel.frame = NSRect(x: 235, y: 37, width: 32, height: 11)
        deviceVolumeSlider.frame = NSRect(x: 268, y: 32, width: bounds.width - 275, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 4, y: bounds.maxY - 0.5))
        separator.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 0.5))
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        separator.lineWidth = 0.5
        separator.stroke()
    }

    func configure(app: SoundPlaybackApp, devices: [SoundOutputDevice]) {
        pid = app.pid
        let presentsAsPlaying = app.playbackState.presentsAsPlaying
        let transitioning = app.playbackState.isTransitioning
        let showsAudioControls = app.isActive && app.playbackState == .playing
        appIsActive = showsAudioControls
        rowIdentifier = app.stableIdentifier
        nameLabel.stringValue = app.name
        if slider.cell?.isHighlighted != true { slider.floatValue = app.volume }
        slider.toolTip = "\(Int((app.volume * 100).rounded()))% volume"
        appVolumeLabel.stringValue = "APP \(Int((app.volume * 100).rounded()))%"
        if app.displayPID > 0 {
            iconView.image = NSRunningApplication(processIdentifier: app.displayPID)?.icon
        } else if let bundleIdentifier = app.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "play.square", accessibilityDescription: app.name)
        }
        playbackButton.image = NSImage(
            systemSymbolName: presentsAsPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: presentsAsPlaying ? "Pause \(app.name)" : "Play \(app.name)"
        )
        playbackButton.setAccessibilityLabel(presentsAsPlaying ? "Pause \(app.name)" : "Play \(app.name)")
        playbackButton.isEnabled = app.bundleIdentifier != nil && !transitioning
        playbackButton.alphaValue = transitioning ? 0.55 : 1
        playbackButton.toolTip = transitioning
            ? (app.playbackState == .starting ? "Starting \(app.name)…" : "Pausing \(app.name)…")
            : presentsAsPlaying ? "Pause \(app.name)" : "Launch and play \(app.name)"

        slider.isEnabled = showsAudioControls
        outputButton.isEnabled = showsAudioControls
        deviceVolumeSlider.isEnabled = showsAudioControls
        iconView.alphaValue = presentsAsPlaying ? 1 : 0.38
        nameLabel.textColor = presentsAsPlaying ? .labelColor : .tertiaryLabelColor
        slider.alphaValue = showsAudioControls ? 1 : 0.35
        outputButton.alphaValue = showsAudioControls ? 1 : 0.35
        deviceVolumeSlider.alphaValue = showsAudioControls ? 1 : 0.35
        slider.isHidden = !showsAudioControls
        appVolumeLabel.isHidden = !showsAudioControls
        outputButton.isHidden = !showsAudioControls
        deviceVolumeLabel.isHidden = !showsAudioControls
        deviceVolumeSlider.isHidden = !showsAudioControls
        needsLayout = true

        if app.playbackState == .starting {
            appVolumeLabel.stringValue = "STARTING"
            detailLabel.stringValue = "Starting playback…"
            detailLabel.textColor = .systemOrange
        } else if app.playbackState == .pausing {
            appVolumeLabel.stringValue = "PAUSING"
            detailLabel.stringValue = "Pausing playback…"
            detailLabel.textColor = .systemOrange
        } else if !presentsAsPlaying {
            appVolumeLabel.stringValue = "INACTIVE"
            detailLabel.stringValue = app.isPermanent ? "Pinned · Inactive" : "Paused · Inactive"
            detailLabel.textColor = .tertiaryLabelColor
        } else { switch app.routeState {
        case .system:
            detailLabel.stringValue = "\(app.kind.rawValue) · \(Int((app.volume * 100).rounded()))%"
            detailLabel.textColor = .tertiaryLabelColor
        case .starting:
            detailLabel.stringValue = "Switching output…"
            detailLabel.textColor = .systemOrange
        case .routed:
            let outputName = devices.first(where: { $0.uid == app.selectedOutputUID })?.name ?? "System"
            detailLabel.stringValue = "\(app.kind.rawValue) · \(shortOutputName(outputName))"
            detailLabel.textColor = .systemGreen
        case let .failed(message):
            detailLabel.stringValue = message
            detailLabel.textColor = .systemRed
        } }

        if showsAudioControls, app.routeState == .system || app.routeState == .routed,
           let warning = selectedDevice(uid: app.selectedOutputUID, devices: devices)?.silenceWarning {
            detailLabel.stringValue = warning + " · adjust device volume"
            detailLabel.textColor = .systemOrange
        }

        let nextDeviceSignature = devices.map { "\($0.id)|\($0.uid)|\($0.name)|\($0.isDefault)" }
        if deviceSignature != nextDeviceSignature { deviceSignature = nextDeviceSignature }
        self.devices = devices
        if showsAudioControls {
            showSelectedOutput(uid: app.selectedOutputUID, devices: devices)
        } else {
            configuredOutputUID = nil
            outputButton.title = "Inactive"
            outputButton.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Inactive")
            deviceVolumeLabel.stringValue = "DEV —"
            deviceVolumeSlider.isEnabled = false
        }
        setAccessibilityLabel("\(app.name), \(app.kind.rawValue), volume \(Int((app.volume * 100).rounded())) percent")
    }

    @objc private func togglePlayback() {
        guard playbackButton.isEnabled else { return }
        onPlaybackToggle?(rowIdentifier)
    }

    @objc private func volumeChanged() {
        slider.toolTip = "\(Int((slider.floatValue * 100).rounded()))% volume"
        appVolumeLabel.stringValue = "APP \(Int((slider.floatValue * 100).rounded()))%"
        onVolumeChange?(slider.floatValue, pid)
    }

    @objc private func showOutputPicker() {
        onOutputPickerHoverChange?(true, pid, configuredOutputUID, devices)
    }

    @objc private func deviceVolumeChanged() {
        guard let device = selectedDevice(uid: configuredOutputUID, devices: devices) else { return }
        let percent = Int((deviceVolumeSlider.floatValue * 100).rounded())
        deviceVolumeLabel.stringValue = "DEV \(percent)%"
        deviceVolumeSlider.toolTip = "\(device.name): \(percent)%"
        onDeviceVolumeChange?(deviceVolumeSlider.floatValue, device.uid)
    }

    func showSelectedOutput(uid: String?, devices: [SoundOutputDevice]) {
        configuredOutputUID = uid
        let device = selectedDevice(uid: uid, devices: devices)
        let name = device.map { shortOutputName($0.name) } ?? "System Output"
        let symbol = device.map(outputSymbol(for:)) ?? "gearshape.fill"
        outputButton.title = "\(name)\(device?.isMuted == true ? " · Muted" : "")  ▾"
        outputButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        outputButton.toolTip = "Choose output — currently \(name)"
        updateDeviceVolume(uid: uid, devices: devices)
    }

    func outputAnchorRect(in view: NSView) -> NSRect {
        view.convert(outputButton.bounds, from: outputButton)
    }

    private func updateDeviceVolume(uid: String?, devices: [SoundOutputDevice]) {
        guard let device = selectedDevice(uid: uid, devices: devices), let volume = device.volume else {
            deviceVolumeLabel.stringValue = "DEV —"
            deviceVolumeSlider.isEnabled = false
            deviceVolumeSlider.toolTip = "Device volume is not software-adjustable"
            return
        }
        deviceVolumeSlider.isEnabled = true
        if deviceVolumeSlider.cell?.isHighlighted != true { deviceVolumeSlider.floatValue = volume }
        let percent = Int((volume * 100).rounded())
        deviceVolumeLabel.stringValue = device.isMuted ? "MUTED" : "DEV \(percent)%"
        deviceVolumeSlider.toolTip = device.isMuted
            ? "\(device.name) is muted. Adjust volume to unmute."
            : "\(device.name): \(percent)%"
    }

    private func selectedDevice(uid: String?, devices: [SoundOutputDevice]) -> SoundOutputDevice? {
        if let uid { return devices.first(where: { $0.uid == uid }) }
        return devices.first(where: \.isDefault)
    }

    private func outputSymbol(for device: SoundOutputDevice) -> String {
        let name = device.name.lowercased()
        if name.contains("airpods") { return "airpodspro" }
        if name.contains("headphone") || name.contains("headset") { return "headphones" }
        if name.contains("macbook") || name.contains("built-in") || name.contains("speaker") {
            return "speaker.wave.2.fill"
        }
        return "hifispeaker.fill"
    }

    private func shortOutputName(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("AirPods") { return "AirPods" }
        if name.localizedCaseInsensitiveContains("MacBook") { return "Speakers" }
        return name
    }
}

private final class SoundOutputPickerView: NSView {
    let representedPID: pid_t
    var onSelection: ((String?) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    let preferredHeight: CGFloat

    private let outputUIDs: [String?]
    private var buttons: [NSButton] = []
    private var trackingAreaReference: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(pid: pid_t, selectedUID: String?, devices: [SoundOutputDevice]) {
        representedPID = pid
        let choices: [(String?, String)] = [(nil, "System Output")] + devices.map {
            ($0.uid, $0.isDefault ? "\($0.name) · Default" : $0.name)
        }
        outputUIDs = choices.map { $0.0 }
        preferredHeight = CGFloat(choices.count * 25 + 8)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        for (index, choice) in choices.enumerated() {
            let selected = choice.0 == selectedUID
            let button = SoundHoverButton(
                title: selected ? "✓  \(choice.1)" : "    \(choice.1)",
                target: self,
                action: #selector(selectOutput(_:))
            )
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 9, weight: selected ? .semibold : .regular)
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            button.setAccessibilityLabel(choice.1)
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 5, y: 4 + CGFloat(index) * 25, width: bounds.width - 10, height: 24)
        }
    }

    @objc private func selectOutput(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < outputUIDs.count else { return }
        onSelection?(outputUIDs[sender.tag])
    }
}

private final class SoundPermanentMediaManagerView: NSView {
    var onPermanentChange: ((SoundPermanentMedia, Bool) -> Void)?
    var onMove: ((String, Int) -> Void)?
    private(set) var preferredHeight: CGFloat = 72

    private let titleLabel = NSTextField(labelWithString: "Permanent Media")
    private let subtitleLabel = NSTextField(labelWithString: "Pinned apps remain visible when inactive")
    private let scrollView = NSScrollView()
    private let contentView = SoundRowsContainerView()
    private var displayedMedia: [SoundPermanentMedia] = []
    private var permanentIDs: [String] = []

    override var isFlipped: Bool { true }

    init(candidates: [SoundPermanentMedia], permanent: [SoundPermanentMedia]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        addSubview(titleLabel)
        subtitleLabel.font = .systemFont(ofSize: 7.5)
        subtitleLabel.textColor = .secondaryLabelColor
        addSubview(subtitleLabel)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = contentView
        addSubview(scrollView)
        configure(candidates: candidates, permanent: permanent)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 10, y: 7, width: bounds.width - 20, height: 14)
        subtitleLabel.frame = NSRect(x: 10, y: 21, width: bounds.width - 20, height: 11)
        scrollView.frame = NSRect(x: 5, y: 36, width: bounds.width - 10, height: max(0, bounds.height - 41))
        contentView.frame.size.width = scrollView.contentSize.width
    }

    func configure(candidates: [SoundPermanentMedia], permanent: [SoundPermanentMedia]) {
        permanentIDs = permanent.map(\.bundleIdentifier)
        let permanentIDSet = Set(permanentIDs)
        displayedMedia = permanent + candidates.filter { !permanentIDSet.contains($0.bundleIdentifier) }
        preferredHeight = min(164, max(72, 41 + CGFloat(max(1, displayedMedia.count)) * 27))
        rebuildRows()
    }

    private func rebuildRows() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.frame = NSRect(x: 0, y: 0, width: max(220, bounds.width - 10), height: CGFloat(max(1, displayedMedia.count)) * 27)

        guard !displayedMedia.isEmpty else {
            let empty = NSTextField(labelWithString: "Play a media app once to add it here.")
            empty.font = .systemFont(ofSize: 8.5)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: 5, y: 8, width: contentView.frame.width - 10, height: 14)
            contentView.addSubview(empty)
            return
        }

        for (index, media) in displayedMedia.enumerated() {
            let isPermanent = permanentIDs.contains(media.bundleIdentifier)
            let y = CGFloat(index) * 27
            let name = NSTextField(labelWithString: media.name)
            name.font = .systemFont(ofSize: 9, weight: isPermanent ? .medium : .regular)
            name.textColor = isPermanent ? .labelColor : .secondaryLabelColor
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 7, y: y + 6, width: contentView.frame.width - 91, height: 14)
            contentView.addSubview(name)

            let pin = SoundHoverButton(title: isPermanent ? "−" : "+", target: self, action: #selector(togglePermanent(_:)))
            pin.tag = index
            pin.isBordered = false
            pin.font = .systemFont(ofSize: 12, weight: .semibold)
            pin.toolTip = isPermanent ? "Remove from permanent media" : "Keep in permanent media"
            pin.setAccessibilityLabel(isPermanent ? "Remove \(media.name) from permanent media" : "Pin \(media.name)")
            pin.frame = NSRect(x: contentView.frame.width - 78, y: y + 2, width: 23, height: 23)
            contentView.addSubview(pin)

            let permanentIndex = permanentIDs.firstIndex(of: media.bundleIdentifier)
            let up = SoundHoverButton(title: "↑", target: self, action: #selector(moveEarlier(_:)))
            up.tag = index
            up.isBordered = false
            up.isEnabled = permanentIndex.map { $0 > 0 } ?? false
            up.setAccessibilityLabel("Move \(media.name) earlier")
            up.alphaValue = up.isEnabled ? 1 : 0.25
            up.frame = NSRect(x: contentView.frame.width - 52, y: y + 2, width: 22, height: 23)
            contentView.addSubview(up)

            let down = SoundHoverButton(title: "↓", target: self, action: #selector(moveLater(_:)))
            down.tag = index
            down.isBordered = false
            down.isEnabled = permanentIndex.map { $0 < permanentIDs.count - 1 } ?? false
            down.setAccessibilityLabel("Move \(media.name) later")
            down.alphaValue = down.isEnabled ? 1 : 0.25
            down.frame = NSRect(x: contentView.frame.width - 28, y: y + 2, width: 22, height: 23)
            contentView.addSubview(down)
        }
    }

    @objc private func togglePermanent(_ sender: NSButton) {
        guard displayedMedia.indices.contains(sender.tag) else { return }
        let media = displayedMedia[sender.tag]
        onPermanentChange?(media, !permanentIDs.contains(media.bundleIdentifier))
    }

    @objc private func moveEarlier(_ sender: NSButton) {
        guard displayedMedia.indices.contains(sender.tag) else { return }
        onMove?(displayedMedia[sender.tag].bundleIdentifier, -1)
    }

    @objc private func moveLater(_ sender: NSButton) {
        guard displayedMedia.indices.contains(sender.tag) else { return }
        onMove?(displayedMedia[sender.tag].bundleIdentifier, 1)
    }
}

import AppKit

final class PetControlView: NSView {
    static let preferredHeight: CGFloat = 360
    var onSettingsChange: ((PetSettings) -> Void)?
    var onRecenter: (() -> Void)?
    private(set) var settings = PetSettings()
    private var activity = PetActivity()
    private let preview = PetCanvasView(frame: .zero)
    private let developmentNote = NSTextField(labelWithString: "UNDER DEVELOPMENT · 后续继续完善")
    private let enabled = NSSwitch()
    private let visibilityLabel = NSTextField(labelWithString: "Show desktop pet")
    private let codex = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let music = NSButton(checkboxWithTitle: "Music", target: nil, action: nil)
    private let fans = NSButton(checkboxWithTitle: "Fans", target: nil, action: nil)
    private let size = NSSlider(value: 1.1, minValue: 0.75, maxValue: 1.6, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "Size")
    private let sizeValue = NSTextField(labelWithString: "110%")
    private let recenter = NSButton(title: "Bring back", target: nil, action: nil)
    private let modes = HoverSegmentedControl(labels: ["Live", "Work", "Music", "Fans"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Pet is off")
    private let note = NSTextField(wrappingLabelWithString: "Drag Capri to place it. No wandering or speech. Codex uses local task start/end markers only; no chats are stored. Music and fans reuse MyBar data. Hide Pet to stop its monitoring.")
    private var pageVisible = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Pet settings")
        addSubview(preview)
        developmentNote.font = .systemFont(ofSize: 8.5, weight: .semibold)
        developmentNote.textColor = .secondaryLabelColor
        developmentNote.alignment = .center
        addSubview(developmentNote)
        for button in [codex, music, fans] {
            button.font = .systemFont(ofSize: 11); button.target = self; button.action = #selector(changed)
            addSubview(button)
        }
        enabled.target = self; enabled.action = #selector(changed)
        enabled.setAccessibilityLabel("Show desktop pet")
        enabled.toolTip = "Show or hide Capri. Hiding stops Pet's background monitoring."
        addSubview(enabled)
        visibilityLabel.font = .systemFont(ofSize: 11, weight: .medium); addSubview(visibilityLabel)
        sizeLabel.font = .systemFont(ofSize: 10, weight: .medium); addSubview(sizeLabel)
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sizeValue.alignment = .right; addSubview(sizeValue)
        codex.toolTip = "Optional local Codex task-state metadata. This adapter may need updating if Codex changes its local format."
        fans.toolTip = "Slow green cyber-eye pulse while any measured fan RPM is above zero. No fan speed changes."
        modes.selectedSegment = 0; modes.controlSize = .small; modes.font = .systemFont(ofSize: 10)
        modes.target = self; modes.action = #selector(previewChanged); modes.setAccessibilityLabel("Pet animation preview")
        addSubview(modes)
        size.controlSize = .small; size.isContinuous = true; size.target = self; size.action = #selector(changed)
        size.setAccessibilityLabel("Pet size"); addSubview(size)
        recenter.controlSize = .small; recenter.bezelStyle = .rounded; recenter.font = .systemFont(ofSize: 10)
        recenter.target = self; recenter.action = #selector(bringBack); recenter.setAccessibilityLabel("Bring desktop pet back on screen")
        addSubview(recenter)
        status.font = .systemFont(ofSize: 10, weight: .medium); status.alignment = .center; addSubview(status)
        note.font = .systemFont(ofSize: 9); note.textColor = .secondaryLabelColor; addSubview(note)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        update(settings: settings, activity: activity)
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func layout() {
        super.layout()
        preview.frame = NSRect(x: 12, y: 0, width: bounds.width - 24, height: 166)
        developmentNote.frame = NSRect(x: 12, y: 2, width: bounds.width - 24, height: 15)
        modes.frame = NSRect(x: 63, y: 167, width: bounds.width - 126, height: 22)
        visibilityLabel.frame = NSRect(x: 16, y: 203, width: 126, height: 18)
        enabled.frame = NSRect(x: 145, y: 198, width: 40, height: 25)
        recenter.frame = NSRect(x: bounds.width - 105, y: 200, width: 90, height: 22)
        codex.frame = NSRect(x: 16, y: 230, width: 76, height: 22)
        music.frame = NSRect(x: 100, y: 230, width: 74, height: 22)
        fans.frame = NSRect(x: 181, y: 230, width: 65, height: 22)
        sizeLabel.frame = NSRect(x: 16, y: 262, width: 42, height: 18)
        size.frame = NSRect(x: 62, y: 257, width: bounds.width - 126, height: 22)
        sizeValue.frame = NSRect(x: bounds.width - 60, y: 262, width: 44, height: 18)
        status.frame = NSRect(x: 14, y: 287, width: bounds.width - 28, height: 17)
        note.frame = NSRect(x: 16, y: 314, width: bounds.width - 32, height: 43)
    }
    func update(settings: PetSettings, activity: PetActivity) {
        self.settings = settings; self.activity = activity
        enabled.state = settings.enabled ? .on : .off
        codex.state = settings.codex ? .on : .off; music.state = settings.music ? .on : .off; fans.state = settings.fans ? .on : .off
        if size.cell?.isHighlighted != true { size.doubleValue = settings.scale }
        sizeValue.stringValue = "\(Int((settings.scale * 100).rounded()))%"
        recenter.isEnabled = settings.enabled
        let codexState = !settings.codex ? "off" : !activity.codexAvailable ? "unavailable" : activity.codexWorking ? "working" : "idle"
        status.stringValue = !PetSpriteAtlas.shared.isAvailable ? "Character artwork unavailable" : !settings.enabled ? "Pet is off · previews still available" :
            "Codex: \(codexState) · Music: \(activity.musicPlaying ? "playing" : "idle") · Fans: \(activity.fansSpinning ? "on" : "off")"
        updatePreview()
    }
    func setPageVisible(_ visible: Bool) { pageVisible = visible; updatePreview() }
    private func updatePreview() {
        var state = activity
        switch modes.selectedSegment {
        case 1: state = PetActivity(codexWorking: true, codexAvailable: true)
        case 2: state = PetActivity(musicPlaying: true)
        case 3: state = PetActivity(fansSpinning: true)
        default: break
        }
        preview.update(state, active: pageVisible, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    @objc private func previewChanged() { updatePreview() }
    @objc private func motionChanged() { updatePreview() }
    @objc private func bringBack() { onRecenter?() }
    @objc private func changed() {
        settings.enabled = enabled.state == .on; settings.codex = codex.state == .on
        settings.music = music.state == .on; settings.fans = fans.state == .on; settings.scale = size.doubleValue
        sizeValue.stringValue = "\(Int((settings.scale * 100).rounded()))%"
        onSettingsChange?(settings)
    }
}

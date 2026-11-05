import AppKit
import QuartzCore
import TypingFeedbackProtocol

final class TypingFeedbackView: NSView {
    var onEnable: ((Bool) -> Void)?
    var onSound: ((String) -> Void)?
    var onVolume: ((Float) -> Void)?
    var onPreview: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onRetry: (() -> Void)?
    var onPermission: (() -> Void)?
    var onChooseSound: (() -> Void)?
    private let toggle = NSButton(checkboxWithTitle: "Typing Feedback", target: nil, action: nil)
    private let picker = NSButton(title: "Gateron Ink Red  ▾", target: nil, action: nil)
    private(set) var selectedSound = MechanicalKeySound.defaultName
    private let volume = NSSlider(value: 0.15, minValue: 0, maxValue: 0.5, target: nil, action: nil)
    private let preview = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Off · Bluetooth headphones only")
    private let confirm = NSButton(title: "Confirm headphones", target: nil, action: nil)
    private let retry = NSButton(title: "", target: nil, action: nil)
    private let permission = NSButton(title: "Allow typing…", target: nil, action: nil)
    var soundPickerAnchor: NSRect { picker.frame }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        toggle.frame = NSRect(x: 8, y: 4, width: 176, height: 20)
        toggle.font = .systemFont(ofSize: 10, weight: .medium)
        toggle.target = self; toggle.action = #selector(enabledChanged)
        toggle.setAccessibilityLabel("Enable typing feedback")
        toggle.toolTip = "Opt-in passive key-down listener. No typed content is read or saved. Bluetooth headphones only."
        addSubview(toggle)
        let note = NSTextField(labelWithString: "HEADPHONES ONLY")
        note.frame = NSRect(x: 220, y: 8, width: 100, height: 12)
        note.font = .systemFont(ofSize: 7.5, weight: .medium); note.textColor = .tertiaryLabelColor
        note.alignment = .right; addSubview(note)
        picker.frame = NSRect(x: 8, y: 26, width: 122, height: 22)
        picker.bezelStyle = .rounded; picker.alignment = .left
        picker.font = .systemFont(ofSize: 10)
        picker.target = self; picker.action = #selector(soundChanged)
        picker.setAccessibilityLabel("Mechanical keyboard sound")
        picker.toolTip = "Real mechanical switch recordings · three variations per switch · preloaded for quick feedback."
        addSubview(picker)
        volume.frame = NSRect(x: 142, y: 29, width: 112, height: 16)
        volume.controlSize = .small; volume.isContinuous = true
        volume.target = self; volume.action = #selector(volumeChanged)
        volume.setAccessibilityLabel("Typing feedback volume")
        volume.toolTip = "Typing feedback volume; does not change headphone or media volume."
        addSubview(volume)
        preview.frame = NSRect(x: 264, y: 25, width: 26, height: 24)
        preview.isBordered = false; preview.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Preview typing sound")
        preview.target = self; preview.action = #selector(previewSound)
        preview.setAccessibilityLabel("Preview typing sound"); preview.toolTip = "Play the same representative click on Bluetooth headphones; rapid clicks never stack."
        addSubview(preview)
        retry.frame = NSRect(x: 294, y: 25, width: 26, height: 24)
        retry.isBordered = false; retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry typing feedback")
        retry.target = self; retry.action = #selector(retryConnection)
        retry.setAccessibilityLabel("Retry typing feedback"); retry.toolTip = "Recheck permission and the selected output"
        addSubview(retry)
        status.frame = NSRect(x: 9, y: 53, width: 310, height: 14)
        status.font = .systemFont(ofSize: 8.5); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail; addSubview(status)
        confirm.frame = NSRect(x: 198, y: 51, width: 124, height: 20)
        confirm.bezelStyle = .rounded; confirm.controlSize = .mini; confirm.font = .systemFont(ofSize: 8.5)
        confirm.target = self; confirm.action = #selector(confirmOutput)
        confirm.toolTip = "Confirm this currently selected Bluetooth device is headphones, not a speaker."
        confirm.isHidden = true; addSubview(confirm)
        permission.frame = NSRect(x: 218, y: 51, width: 104, height: 20)
        permission.bezelStyle = .rounded; permission.controlSize = .mini
        permission.font = .systemFont(ofSize: 8.5); permission.target = self
        permission.action = #selector(allowTyping)
        permission.setAccessibilityLabel("Allow typing Input Monitoring")
        permission.isHidden = true; addSubview(permission)
        setAccessibilityElement(false)
        update(TypingFeedbackState())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill()
    }
    func update(_ state: TypingFeedbackState) {
        toggle.state = state.settings.enabled ? .on : .off
        selectedSound = state.settings.sound; picker.title = "\(selectedSound)  ▾"
        picker.toolTip = "\(selectedSound) · \(MechanicalKeySound.character(for: selectedSound)) · real switch recordings"
        if !volume.isHighlighted { volume.floatValue = state.settings.volume }
        preview.isEnabled = state.settings.volume > 0
        retry.isEnabled = true
        status.stringValue = state.status; status.toolTip = state.status
        status.frame.size.width = state.canConfirmHeadphones ? 184 : state.permissionNeeded ? 204 : 310
        confirm.isHidden = !state.canConfirmHeadphones
        permission.isHidden = !state.permissionNeeded
        status.textColor = state.listening ? .systemGreen : .secondaryLabelColor
    }
    @objc private func enabledChanged() { onEnable?(toggle.state == .on) }
    @objc private func soundChanged() { onChooseSound?() }
    func chooseSound(_ name: String) {
        guard MechanicalKeySound.names.contains(name) else { return }
        selectedSound = name; picker.title = "\(name)  ▾"; onSound?(name)
    }
    @objc private func volumeChanged() { onVolume?(volume.floatValue) }
    @objc private func previewSound() { onPreview?() }
    @objc private func confirmOutput() { onConfirm?() }
    @objc private func retryConnection() { onRetry?() }
    @objc private func allowTyping() { onPermission?() }
}

/// An inline choice panel: no nested NSMenu tracking inside the status-item menu.
final class TypingSoundPickerView: NSView {
    var onSelection: ((String) -> Void)?
    static let preferredSize = NSSize(width: 244, height: 100)
    override var isFlipped: Bool { true }
    init(selected: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        wantsLayer = true
        layer?.cornerRadius = 8; layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = 5
        for (index, name) in MechanicalKeySound.names.enumerated() {
            let button = NSButton(title: (name == selected ? "✓ " : "   ") + name, target: self, action: #selector(selectSound(_:)))
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 10, weight: name == selected ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingTail
            button.frame = NSRect(x: 6 + CGFloat(index % 2) * 118, y: 6 + CGFloat(index / 2) * 22, width: 116, height: 22)
            button.setAccessibilityLabel("Select \(name) typing sound")
            // A tooltip here covers neighboring choices. Keep the description
            // available to accessibility without a floating overlay.
            button.setAccessibilityHelp(MechanicalKeySound.character(for: name))
            addSubview(button)
        }
        refreshAppearance()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearance()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
    private func refreshAppearance() {
        // CGColor freezes the appearance in which it was resolved. Menu views
        // can be created under the app's dark appearance then attached to a
        // light status menu (or vice versa), so resolve in this view's context.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            CATransaction.commit()
            for button in subviews.compactMap({ $0 as? NSButton }) {
                button.attributedTitle = NSAttributedString(string: button.title,
                    attributes: [.font: button.font ?? NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor.labelColor])
            }
        }
        needsDisplay = true
    }
    @objc private func selectSound(_ sender: NSButton) {
        guard MechanicalKeySound.names.indices.contains(sender.tag) else { return }
        onSelection?(MechanicalKeySound.names[sender.tag])
    }
}

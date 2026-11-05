import AppKit
import TrackpadGestureCore

final class TrackpadGesturesSettingsView: NSView {
    var onSettings: ((TrackpadGestureSettings) -> Void)?
    var onRecheck: (() -> Void)?
    var onAccessibility: (() -> Void)?
    var onSystemTrackpad: (() -> Void)?
    private var settings = TrackpadGestureSettings()
    private let enabled = NSSwitch()
    private let sensitivity = HoverSegmentedControl(labels: ["Low", "Medium", "High"], trackingMode: .selectOne, target: nil, action: nil)
    private let reverse = NSButton(checkboxWithTitle: "Reverse Swipe Direction", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Off · no trackpad monitoring")
    private let permission = NSButton(title: "Open Accessibility…", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
    }
    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Trackpad Gestures settings")
        let title = NSTextField(labelWithString: "Trackpad Gestures")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let summary = NSTextField(wrappingLabelWithString: "Four fingers. One tab. Only in your foreground browser.")
        summary.textColor = .secondaryLabelColor; summary.font = .systemFont(ofSize: 12)
        let label = NSTextField(labelWithString: "Enable Four-Finger Tab Switching")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        enabled.target = self; enabled.action = #selector(changed)
        enabled.setAccessibilityLabel(label.stringValue)
        let row = NSStackView(views: [label, NSView(), enabled]); row.orientation = .horizontal
        row.alignment = .centerY
        let directions = NSTextField(labelWithString: "Swipe left → next tab     ·     Swipe right → previous tab")
        directions.font = .systemFont(ofSize: 11); directions.textColor = .secondaryLabelColor
        let sensitivityLabel = NSTextField(labelWithString: "Sensitivity")
        sensitivityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sensitivity.selectedSegment = 1; sensitivity.font = .systemFont(ofSize: 12)
        sensitivity.target = self; sensitivity.action = #selector(changed)
        sensitivity.setAccessibilityLabel("Four-finger swipe sensitivity")
        reverse.font = .systemFont(ofSize: 12); reverse.target = self; reverse.action = #selector(changed)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.setAccessibilityLabel("Gesture availability")
        permission.target = self; permission.action = #selector(openPermission)
        let recheck = NSButton(title: "Recheck", target: self, action: #selector(recheck))
        let trackpad = NSButton(title: "Trackpad Settings…", target: self, action: #selector(openTrackpad))
        for button in [permission, recheck, trackpad] { button.bezelStyle = .rounded; button.controlSize = .small }
        let buttons = NSStackView(views: [permission, trackpad, recheck]); buttons.spacing = 8
        let note = NSTextField(wrappingLabelWithString: "macOS four-finger desktop switching must be off. Choosing Three Fingers can leave four fingers enabled too; use Off if the conflict remains. MyBar never changes this setting automatically. Then click Recheck.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let privacy = NSTextField(wrappingLabelWithString: "Experimental private Apple touch API · not Mac App Store compatible. Accessibility sends tab shortcuts only. No keyboard capture, browser contents or history. Monitoring stops when disabled; touches are not monitored outside supported browsers.")
        privacy.font = .systemFont(ofSize: 10); privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, summary, row, directions, sensitivityLabel, sensitivity, reverse, status, buttons, note, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sensitivity.widthAnchor.constraint(equalToConstant: 260),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        update(settings, status: status.stringValue, permissionNeeded: false)
    }
    func update(_ settings: TrackpadGestureSettings, status: String, permissionNeeded: Bool) {
        self.settings = settings
        enabled.state = settings.enabled ? .on : .off
        sensitivity.selectedSegment = SwipeSensitivity.allCases.firstIndex(of: settings.sensitivity) ?? 1
        reverse.state = settings.reversed ? .on : .off
        self.status.stringValue = status
        permission.isHidden = !permissionNeeded
        self.status.textColor = permissionNeeded || status.hasPrefix("Paused") || status.contains("unavailable") ? .systemOrange : .secondaryLabelColor
    }
    @objc private func changed() {
        settings.enabled = enabled.state == .on
        settings.sensitivity = SwipeSensitivity.allCases[max(0, min(2, sensitivity.selectedSegment))]
        settings.reversed = reverse.state == .on
        onSettings?(settings)
    }
    @objc private func openPermission() { onAccessibility?() }
    @objc private func openTrackpad() { onSystemTrackpad?() }
    @objc private func recheck() { onRecheck?() }
}

final class MyBarSettingsWindowController: NSWindowController {
    init(manager: TrackpadGestureManager) {
        let view = TrackpadGesturesSettingsView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MyBar Settings"; window.contentView = view; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MyBar.TrackpadSettingsWindow"); window.center()
        super.init(window: window)
        view.onSettings = { [weak manager] in manager?.setSettings($0) }
        view.onRecheck = { [weak manager] in manager?.retry() }
        view.onAccessibility = { Self.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
        view.onSystemTrackpad = { Self.openSettings("x-apple.systempreferences:com.apple.Trackpad-Settings.extension") }
        manager.onChange = { [weak view, weak manager] in
            guard let view, let manager else { return }
            view.update(manager.settings, status: manager.status, permissionNeeded: manager.needsPermission)
        }
        view.update(manager.settings, status: manager.status, permissionNeeded: manager.needsPermission)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private static func openSettings(_ value: String) {
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }
}

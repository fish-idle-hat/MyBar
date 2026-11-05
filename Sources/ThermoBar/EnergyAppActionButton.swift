import AppKit

/// A transparent hit target over each energy row; retains the pressed app while rankings refresh.
final class EnergyAppActionButton: NSButton {
    var app: TopAppMetrics?
    var onOpen: ((TopAppMetrics, Bool) -> Void)?
    private var pressedApp: TopAppMetrics?
    private var revealOnClick = false
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        target = self
        action = #selector(openApp)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEnabled { NSCursor.pointingHand.set() }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        pressedApp = app
        revealOnClick = event.modifierFlags.contains(.option)
        super.mouseDown(with: event)
        pressedApp = nil
        revealOnClick = false
    }

    @objc private func openApp() {
        if let selected = pressedApp ?? app { onOpen?(selected, revealOnClick) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, hovered || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.18 : 0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
        }
    }
}

enum EnergyAppNavigation {
    static func open(_ app: TopAppMetrics, revealOnly: Bool) {
        let reveal = {
            guard let url = app.applicationURL ?? app.executableURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                let alert = NSAlert()
                alert.messageText = "Process location unavailable"
                alert.informativeText = "\(app.name) may have exited or moved. Refresh the list and try again."
                alert.runModal()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        guard !revealOnly, let url = app.applicationURL,
              let running = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && $0.activationPolicy == .regular
              }), !running.isTerminated else { reveal(); return }
        // Reopen requests restore an application's window even when its last window was closed.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { reveal() } }
        }
    }
}

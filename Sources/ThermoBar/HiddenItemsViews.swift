import AppKit

final class OrganizerHostView: NSView {
    private let details: SystemDetailsView
    private let row: HiddenItemsRow
    override var isFlipped: Bool { true }

    init(details: SystemDetailsView, manager: MenuBarOrganizer) {
        self.details = details
        row = HiddenItemsRow(manager: manager)
        super.init(frame: NSRect(x: 0, y: 0, width: details.frame.width, height: details.frame.height + 30))
        addSubview(row)
        addSubview(details)
        manager.onChange = { [weak self, weak manager] in
            self?.row.reload()
            manager?.updateManagementView()
        }
        resizeForDetails()
        row.reload()
    }
    required init?(coder: NSCoder) { nil }

    func resizeForDetails() {
        frame.size = NSSize(width: details.frame.width, height: details.frame.height + 30)
        row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 30)
        details.frame.origin = NSPoint(x: 0, y: 30)
    }
}

final class HiddenItemsRow: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("local.thermobar.organizer.item")
    private let manager: MenuBarOrganizer
    private let scroll = NSScrollView()
    private let document = NSView()
    private let manage = NSButton(title: "+ Manage", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "Organize menu bar icons")
    private var insertionX: CGFloat?
    override var isFlipped: Bool { true }

    init(manager: MenuBarOrganizer) {
        self.manager = manager
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 30))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = document
        addSubview(scroll)
        manage.isBordered = false
        manage.font = .systemFont(ofSize: 10, weight: .medium)
        manage.target = self
        manage.action = #selector(openManage)
        addSubview(manage)
        emptyLabel.font = .systemFont(ofSize: 10)
        emptyLabel.textColor = .secondaryLabelColor
        addSubview(emptyLabel)
        registerForDraggedTypes([Self.pasteboardType])
        needsLayout = true
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 10, y: 2, width: bounds.width - 88, height: 26)
        manage.frame = NSRect(x: bounds.width - 77, y: 3, width: 69, height: 24)
        emptyLabel.frame = NSRect(x: 14, y: 9, width: bounds.width - 98, height: 16)
    }

    func reload() {
        document.subviews.forEach { $0.removeFromSuperview() }
        let hiddenItems = manager.hiddenItems
        emptyLabel.stringValue = manager.collectionSummary
        emptyLabel.isHidden = !hiddenItems.isEmpty
        emptyLabel.toolTip = manager.selected.isEmpty ? nil : "Selection is saved in Manage. Original menu bar icons have not been hidden."
        scroll.isHidden = hiddenItems.isEmpty
        document.frame = NSRect(x: 0, y: 0, width: max(1, CGFloat(hiddenItems.count) * 29), height: 26)
        for (index, item) in hiddenItems.enumerated() {
            let button = OrganizerIconButton(item: item, frame: NSRect(x: CGFloat(index) * 29, y: 1, width: 27, height: 24))
            button.onClick = { [weak manager] in manager?.activate(id: item.id) }
            button.onNativeContext = { [weak manager] in manager?.activate(id: item.id, rightClick: true) }
            button.onRestore = { [weak manager] in manager?.restore(id: item.id) }
            button.toolTip = item.name + (manager.isHidden ? "\nHidden · click to reveal original controls" : "\nSelected · currently revealed")
            document.addSubview(button)
        }
        needsDisplay = true
        needsLayout = true
    }

    @objc private func openManage() { manager.openManagement() }

    private func accept(_ sender: NSDraggingInfo) -> Bool {
        manager.isHidden && sender.draggingSource is OrganizerIconButton
            && sender.draggingPasteboard.string(forType: Self.pasteboardType) != nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accept(sender) else { return [] }
        insertionX = min(bounds.width - 82, max(11, convert(sender.draggingLocation, from: nil).x))
        needsDisplay = true
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertionX = nil; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { insertionX = nil; needsDisplay = true }
        guard accept(sender), let sourceID = sender.draggingPasteboard.string(forType: Self.pasteboardType) else { return false }
        let point = document.convert(sender.draggingLocation, from: nil)
        let index = min(manager.selected.count, max(0, Int(point.x / 29)))
        manager.reorder(id: sourceID, before: index < manager.selected.count ? manager.selected[index].id : "")
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let insertionX {
            NSColor.controlAccentColor.setFill()
            NSRect(x: insertionX, y: 5, width: 2, height: 20).fill()
        }
    }
}

final class OrganizerIconButton: NSButton, NSDraggingSource {
    let item: MenuBarItemIdentity
    var onClick: (() -> Void)?
    var onNativeContext: (() -> Void)?
    var onRestore: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(item: MenuBarItemIdentity, frame: NSRect) {
        self.item = item
        super.init(frame: frame)
        title = ""
        isBordered = false
        image = NSWorkspace.shared.icon(forFile: item.applicationPath)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(item.name)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { onClick?(); return }
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) < 4 { continue }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(item.id, forType: HiddenItemsRow.pasteboardType)
            let drag = NSDraggingItem(pasteboardWriter: pasteboard)
            drag.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [drag], event: next, source: self)
            return
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let native = NSMenuItem(title: "Open Original Context Menu", action: #selector(nativeContext), keyEquivalent: "")
        native.target = self
        menu.addItem(native)
        let restore = NSMenuItem(title: "Restore to Menu Bar", action: #selector(restoreItem), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func nativeContext() { onNativeContext?() }
    @objc private func restoreItem() { onRestore?() }
}

final class HiddenItemsManagementView: NSView {
    private let manager: MenuBarOrganizer
    private let instructions = NSTextField(wrappingLabelWithString:
        "Experimental fallback: direct drops from macOS status items are unsupported. Select items, click Prepare, then ⌘-drag their REAL icons LEFT of | inside the menu bar. Keep MyBar RIGHT of |. Verify & Hide checks actual visibility and restores on failure.")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let document = FlippedOrganizerDocument()
    private var buttons: [NSButton] = []
    override var isFlipped: Bool { true }

    init(manager: MenuBarOrganizer) {
        self.manager = manager
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
        instructions.font = .systemFont(ofSize: 11)
        instructions.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11, weight: .medium)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        [instructions, status, scroll].forEach(addSubview)
        for (title, selector) in [("Enable Accessibility", #selector(permission)), ("Prepare", #selector(prepare)),
                                  ("Refresh", #selector(refresh)), ("Verify & Hide", #selector(hide)),
                                  ("Reveal", #selector(reveal)), ("Restore All", #selector(restoreAll))] {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 10)
            buttons.append(button)
            addSubview(button)
        }
        render()
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        instructions.frame = NSRect(x: 16, y: 14, width: bounds.width - 32, height: 66)
        status.frame = NSRect(x: 16, y: 85, width: bounds.width - 32, height: 38)
        scroll.frame = NSRect(x: 12, y: 126, width: bounds.width - 24, height: max(70, bounds.height - 206))
        let widths: [CGFloat] = [145, 75, 75, 110, 75, 100]
        var x: CGFloat = 14
        var y = bounds.height - 72
        for (i, button) in buttons.enumerated() {
            if i == 3 { x = 14; y += 32 }
            button.frame = NSRect(x: x, y: y, width: widths[i], height: 26)
            x += widths[i] + 6
        }
    }

    func render() {
        instructions.stringValue = manager.supportsWindowVerifiedHiding
            ? "Experimental fallback: direct drops from macOS status items are unsupported. Select items, click Prepare, then ⌘-drag their REAL icons LEFT of | inside the menu bar. Keep MyBar RIGHT of |. Verify & Hide checks actual visibility and restores on failure."
            : "Experimental macOS 27 helper: select apps, then Hide Selected. No divider or dragging needed. This handles all icons of a selected app together. Originals are verified before appearing here. Reveal / Restore All releases the restriction. Helper failure does not stop monitoring."
        status.stringValue = manager.scanning ? "Reading status items…" : manager.message
        document.subviews.forEach { $0.removeFromSuperview() }
        let selectedIDs = Set(manager.selected.map(\.id))
        var y: CGFloat = 0
        for (index, item) in manager.items.enumerated() {
            let button = NSButton(checkboxWithTitle: item.identity.name + (item.supported ? "" : " · Unsupported / protected"),
                                  target: self, action: #selector(selectItem(_:)))
            button.tag = index
            button.state = selectedIDs.contains(item.identity.id) ? .on : .off
            button.isEnabled = item.supported && !manager.isHidden && !manager.scanning
            button.frame = NSRect(x: 4, y: y, width: bounds.width - 52, height: 26)
            button.font = .systemFont(ofSize: 11)
            button.toolTip = item.identity.applicationPath
            document.addSubview(button)
            y += 28
        }
        for item in manager.selected where !manager.items.contains(where: { $0.identity.id == item.id }) {
            let label = NSTextField(labelWithString: "\(item.name) · Not currently accessible")
            label.frame = NSRect(x: 8, y: y, width: bounds.width - 52, height: 24)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
            document.addSubview(label)
            y += 26
        }
        document.frame.size = NSSize(width: max(200, bounds.width - 40), height: max(1, y))
        buttons[0].title = manager.hasPermission ? "Permission Settings" : "Enable Access"
        buttons[1].title = manager.supportsWindowVerifiedHiding ? "Prepare" : "Per-App Mode"
        buttons[3].title = manager.supportsWindowVerifiedHiding ? "Verify & Hide" : "Hide Selected"
        buttons[1].isEnabled = manager.supportsWindowVerifiedHiding && manager.hasPermission && !manager.scanning
        buttons[3].isEnabled = manager.supportsHiding && manager.hasPermission && !manager.scanning && !manager.isHidden && !manager.selected.isEmpty
        buttons[1].toolTip = manager.supportsWindowVerifiedHiding ? nil : manager.compatibilityMessage
        buttons[3].toolTip = manager.supportsWindowVerifiedHiding ? nil : "Hide all menu bar icons owned by the selected apps using the isolated experimental helper."
        needsLayout = true
    }
    @objc private func permission() { manager.requestPermission() }
    @objc private func prepare() { manager.preparePlacement() }
    @objc private func refresh() { manager.refresh() }
    @objc private func hide() { manager.hideVerifiedPlacement() }
    @objc private func reveal() { manager.revealAll() }
    @objc private func restoreAll() { manager.restoreAll() }
    @objc private func selectItem(_ sender: NSButton) {
        guard manager.items.indices.contains(sender.tag) else { return }
        manager.select(manager.items[sender.tag], enabled: sender.state == .on)
    }
}

private final class FlippedOrganizerDocument: NSView {
    override var isFlipped: Bool { true }
}

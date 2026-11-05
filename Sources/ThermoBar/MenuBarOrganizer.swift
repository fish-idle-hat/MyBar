import AppKit
import ApplicationServices
import MenuBarControlProtocol

struct MenuBarItemIdentity: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let applicationPath: String
}

struct DiscoveredMenuBarItem {
    let identity: MenuBarItemIdentity
    let element: AXUIElement
    let frame: CGRect
    let windowID: CGWindowID?
    let supported: Bool
}

enum MenuBarItemDiscovery {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func scan() -> [DiscoveredMenuBarItem] {
        guard AXIsProcessTrusted() else { return [] }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        var result: [DiscoveredMenuBarItem] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            guard let extras = value(application, kAXExtrasMenuBarAttribute),
                  CFGetTypeID(extras) == AXUIElementGetTypeID() else { continue }
            let bar = unsafeBitCast(extras, to: AXUIElement.self)
            guard let children = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for (index, element) in children.enumerated() {
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                      let sizeValue = value(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero
                var size = CGSize.zero
                guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                      AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
                      size.width > 0, size.height > 0, size.height <= 60 else { continue }
                let frame = CGRect(origin: point, size: size)
                if value(element, kAXHiddenAttribute) as? Bool == true { continue }
                let label = (value(element, kAXDescriptionAttribute) as? String)
                    ?? (value(element, kAXTitleAttribute) as? String) ?? "Item \(index + 1)"
                let identifier = (value(element, kAXIdentifierAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "slot:\(index)"
                let bundle = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
                let identity = MenuBarItemIdentity(id: bundle + ":" + identifier,
                    name: "\(app.localizedName ?? bundle) · \(label)", bundleID: bundle,
                    applicationPath: app.bundleURL?.path ?? "")
                let window = windows.first { entry in
                    guard (entry[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                          (entry[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                          let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                    return abs(rect.midX - frame.midX) < 4 && abs(rect.midY - frame.midY) < 4
                }
                // Apple system extras and unidentified owners are deliberately discovery-only.
                let supported = !bundle.hasPrefix("com.apple.") && app.bundleURL != nil
                result.append(DiscoveredMenuBarItem(identity: identity, element: element, frame: frame,
                    windowID: (window?[kCGWindowNumber as String] as? NSNumber)?.uint32Value, supported: supported))
            }
        }
        let labelCounts = Dictionary(grouping: result, by: { $0.identity.bundleID + ":" + $0.identity.name })
        return result.map { item in
            let ambiguous = item.identity.id.contains(":slot:")
                && (labelCounts[item.identity.bundleID + ":" + item.identity.name]?.count ?? 0) > 1
            return DiscoveredMenuBarItem(identity: item.identity, element: item.element, frame: item.frame,
                                         windowID: item.windowID, supported: item.supported && !ambiguous)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }
}

final class MenuBarOrganizer: NSObject {
    var onChange: (() -> Void)?
    var onDismissMenu: (() -> Void)?
    var mainItemFrame: (() -> NSRect?)?
    private(set) var selected: [MenuBarItemIdentity]
    private(set) var items: [DiscoveredMenuBarItem] = []
    private(set) var isHidden = false
    private(set) var message = "Manage menu bar items"
    private(set) var scanning = false
    private var divider: NSStatusItem?
    private var safetyTimer: Timer?
    private var scanGeneration = 0
    private var visibilityGeneration = 0
    private let defaults: UserDefaults
    private let discoveryQueue = DispatchQueue(label: "ThermoBar.menu-item-discovery", qos: .utility)
    private var managementPanel: NSPanel?
    private let menuHelper = MenuBarHelperClient()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.data(forKey: "ThermoBar.HiddenItems.v1").flatMap {
            try? JSONDecoder().decode([MenuBarItemIdentity].self, from: $0)
        } ?? []
        super.init()
        menuHelper.onUnexpectedExit = { [weak self] reason in
            guard let self else { return }
            self.revealAll()
            self.message = reason
            self.onChange?()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged(_:)),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                             NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged(_:)), name: notification, object: nil)
        }
    }

    deinit {
        safetyTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var hasPermission: Bool { AXIsProcessTrusted() }

    // Selection is a plan, not evidence that the original icon has disappeared.
    // Never populate the hidden-items collection until the visibility check succeeds.
    var hiddenItems: [MenuBarItemIdentity] { isHidden ? selected : [] }
    var collectionSummary: String {
        selected.isEmpty ? "Organize menu bar icons" : "\(selected.count) selected · Not hidden"
    }
    var supportsWindowVerifiedHiding: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }
    var supportsHiding: Bool { supportsWindowVerifiedHiding || (MenuBarHidingPolicy.experimentalActivationAllowed && menuHelper.available) }
    var compatibilityMessage: String {
        guard MenuBarHidingPolicy.experimentalActivationAllowed else {
            return "Experimental hiding is disabled: system-control preservation failed on this macOS build. Saved choices are retained; monitoring is unaffected."
        }
        return menuHelper.available
            ? "Experimental per-app mode · Select apps, then Hide Selected. No divider or dragging is needed. All icons belonging to a selected app are handled together."
            : "Experimental menu bar helper is not installed. Originals remain visible; hardware monitoring is unaffected."
    }

    private var dividerFrame: NSRect? {
        guard let button = divider?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func refresh() {
        guard hasPermission else {
            revealAll()
            items = []
            message = "Enable Access to discover real status items (Device Control and Data Access on macOS 27)."
            onChange?()
            return
        }
        guard !scanning, !isHidden else { return }
        scanning = true
        scanGeneration += 1
        let generation = scanGeneration
        onChange?()
        discoveryQueue.async { [weak self] in
            let items = MenuBarItemDiscovery.scan()
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                self.scanning = false
                self.items = items
                self.selected = self.selected.map { saved in items.first { $0.identity.id == saved.id }?.identity ?? saved }
                self.persist()
                self.message = !self.supportsWindowVerifiedHiding ? self.compatibilityMessage
                    : items.isEmpty ? "No accessible status items found. Custom items may be unsupported."
                    : "Select items, ⌘-drag their real icons left of the | divider, then verify."
                self.onChange?()
            }
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func preparePlacement() {
        guard supportsWindowVerifiedHiding else {
            message = compatibilityMessage
            onChange?()
            return
        }
        revealAll()
        if divider == nil {
            let item = NSStatusBar.system.statusItem(withLength: 18)
            item.autosaveName = "ThermoBar.OrganizerDivider"
            item.behavior = []
            item.button?.title = "|"
            item.button?.toolTip = "MyBar divider: ⌘-drag selected third-party icons to its LEFT. Keep MyBar to its RIGHT."
            item.button?.target = self
            item.button?.action = #selector(dividerClicked)
            divider = item
        }
        message = "⌘-drag only selected icons left of |, staying inside the menu bar."
        onChange?()
    }

    func select(_ item: DiscoveredMenuBarItem, enabled: Bool) {
        guard item.supported else { return }
        revealAll()
        let group = supportsWindowVerifiedHiding ? [item] : items.filter { $0.identity.bundleID == item.identity.bundleID && $0.supported }
        let choices = group.isEmpty ? [item] : group
        let choiceIDs = Set(choices.map(\.identity.id))
        selected.removeAll { choiceIDs.contains($0.id) || (!supportsWindowVerifiedHiding && $0.bundleID == item.identity.bundleID) }
        if enabled { selected.append(contentsOf: choices.map(\.identity)) }
        message = supportsWindowVerifiedHiding
            ? "Selection saved, not hidden yet. Arrange originals with Prepare, then Verify & Hide."
            : compatibilityMessage
        persist()
        onChange?()
    }

    func reorder(id: String, before target: String) {
        guard id != target, let source = selected.firstIndex(where: { $0.id == id }) else { return }
        let item = selected.remove(at: source)
        if target.isEmpty { selected.append(item); persist(); onChange?(); return }
        guard let destination = selected.firstIndex(where: { $0.id == target }) else {
            selected.insert(item, at: min(source, selected.count)); return
        }
        selected.insert(item, at: destination)
        persist()
        onChange?()
    }

    /// Public NSStatusItem spacing pushes a manually arranged group offscreen.
    /// Fail closed unless every window to the left is explicitly selected and identifiable.
    func hideVerifiedPlacement() {
        guard supportsWindowVerifiedHiding else {
            hideWithExperimentalHelper()
            return
        }
        guard hasPermission, !scanning, !isHidden, let dividerFrame = dividerFrame,
              let mainFrame = mainItemFrame?(), let screen = NSScreen.screens.first,
              NSScreen.screens.count == 1, !selected.isEmpty,
              dividerFrame.maxX <= mainFrame.minX else {
            message = "Reveal and refresh first. Use one display, with MyBar RIGHT of |."
            onChange?(); return
        }
        let selectedIDs = Set(selected.map(\.id))
        // Scan immediately before committing, since native Command-drag may have changed positions.
        scanning = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        onChange?()
        discoveryQueue.async { [weak self] in
            let scanned = MenuBarItemDiscovery.scan()
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.items = scanned
                guard generation == self.visibilityGeneration else { self.onChange?(); return }
                let left = scanned.filter { $0.frame.maxX <= dividerFrame.minX + 1 }
                let knownIDs = Set(left.compactMap(\.windowID))
                let selectedOnLeft = Set(left.filter(\.supported).map(\.identity.id))
                let unknownWindow = windows.contains { window in
                    guard (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                          let bounds = window[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                          rect.width > 1, rect.maxX <= dividerFrame.minX + 1,
                          rect.minX >= screen.frame.minX else { return false }
                    let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
                    return !knownIDs.contains(id)
                }
                guard self.hasPermission, selectedIDs == Set(self.selected.map(\.id)),
                      selectedOnLeft == selectedIDs, left.count == selectedIDs.count,
                      left.allSatisfy({ $0.supported && $0.windowID != nil }), !unknownWindow,
                      self.dividerFrame == dividerFrame else {
                    self.message = "Placement not verified. Only selected supported icons may be left of |. Nothing was hidden."
                    self.onChange?(); return
                }
                self.divider?.button?.title = ""
                self.divider?.length = 10_000
                // Allow WindowServer to settle, then verify the original windows really left the visible bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard generation == self.visibilityGeneration else { return }
                    let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
                    let stillVisible = visible.contains { window in
                        let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
                        guard knownIDs.contains(id), let bounds = window[kCGWindowBounds as String] as? [String: Any],
                              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                        return rect.intersects(CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: 60))
                    }
                    let sourceExited = left.contains { item in
                        var pid: pid_t = 0
                        return AXUIElementGetPid(item.element, &pid) != .success
                            || NSRunningApplication(processIdentifier: pid)?.isTerminated != false
                    }
                    if stillVisible || !self.hasPermission || sourceExited {
                        self.revealAll()
                        self.message = "macOS did not confirm hiding. Original items have been revealed."
                    } else {
                        self.isHidden = true
                        self.message = "Hidden · click an icon to reveal its original controls"
                        self.startSafetyChecks()
                    }
                    self.onChange?()
                }
            }
        }
    }

    func revealAll() {
        visibilityGeneration += 1
        scanGeneration += 1
        scanning = false
        menuHelper.stop()
        safetyTimer?.invalidate()
        safetyTimer = nil
        divider?.length = 18
        divider?.button?.title = "|"
        if isHidden { message = "Original icons revealed. Use Hide Selected to hide them again." }
        isHidden = false
        onChange?()
    }

    func restore(id: String) {
        let owner = selected.first { $0.id == id }?.bundleID
        revealAll()
        selected.removeAll { $0.id == id }
        if !supportsWindowVerifiedHiding, let owner {
            selected.removeAll { $0.bundleID == owner }
        }
        persist()
        message = supportsWindowVerifiedHiding ? "Restored. ⌘-drag this icon RIGHT of | before hiding the remaining group."
            : "Originals restored. This app is no longer selected."
        onChange?()
    }

    func restoreAll() {
        revealAll()
        selected = []
        persist()
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
        message = "All icons restored to the menu bar."
        onChange?()
    }

    func activate(id: String, rightClick: Bool = false) {
        revealAll()
        onDismissMenu?()
        message = "Original icons revealed; click the real item if its custom menu cannot open."
        onChange?()
        let expectedName = selected.first { $0.id == id }?.name
        discoveryQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            let item = MenuBarItemDiscovery.scan().first { $0.identity.id == id && $0.identity.name == expectedName && $0.supported }
            guard let item else { return }
            var actions: CFArray?
            AXUIElementCopyActionNames(item.element, &actions)
            let available = actions as? [String] ?? []
            let action = rightClick ? kAXShowMenuAction : kAXPressAction
            if available.contains(action) { _ = AXUIElementPerformAction(item.element, action as CFString) }
            DispatchQueue.main.async { self?.onChange?() }
        }
    }

    func openManagement() {
        onDismissMenu?()
        if managementPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Menu Bar Organizer · Experimental"
            panel.minSize = NSSize(width: 540, height: 380)
            panel.isReleasedWhenClosed = false
            panel.contentView = HiddenItemsManagementView(manager: self)
            panel.center()
            managementPanel = panel
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.managementPanel?.makeKeyAndOrderFront(nil)
        }
        refresh()
    }

    func updateManagementView() {
        (managementPanel?.contentView as? HiddenItemsManagementView)?.render()
    }

    func stop() {
        revealAll()
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
    }

    func crashHelperForIsolationCheck() { menuHelper.crashForIsolationCheck() }

    @objc private func dividerClicked() { revealAll(); openManagement() }
    @objc private func screenChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == getpid() || menuHelper.owns(processID: app.processIdentifier) { return }
        revealAll()
        message = "Layout changed · icons revealed for safety."
        onChange?()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(selected) { defaults.set(data, forKey: "ThermoBar.HiddenItems.v1") }
    }
    private func startSafetyChecks() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.hasPermission { self.revealAll(); self.message = "Permission changed · icons revealed."; self.onChange?() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    /// The private API is process-scoped. Acknowledgement is not considered successful hiding:
    /// re-read AX positions and require selected owners to disappear and unselected items to remain.
    private func hideWithExperimentalHelper() {
        guard hasPermission, MenuBarHidingPolicy.experimentalActivationAllowed, menuHelper.available, !scanning, !isHidden, !selected.isEmpty else {
            message = !hasPermission ? "Enable Access first so actual icon visibility can be verified." : compatibilityMessage
            onChange?(); return
        }
        let bundles = Set(selected.map(\.bundleID))
        guard bundles.allSatisfy(MenuBarHidingPolicy.canHide) else {
            message = "Selection contains a protected or unidentified owner. Nothing was hidden."
            onChange?(); return
        }
        let screens = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.maxY,
                   width: screen.frame.width, height: 60)
        }
        scanning = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        message = "Checking original icons…"
        onChange?()
        discoveryQueue.async { [weak self] in
            let before = MenuBarItemDiscovery.scan().filter { item in screens.contains { $0.intersects(item.frame) } }
            DispatchQueue.main.async {
                guard let self, generation == self.visibilityGeneration else { return }
                let found = Set(before.map { $0.identity.bundleID })
                guard self.hasPermission, bundles.isSubset(of: found),
                      Set(self.selected.map(\.bundleID)) == bundles else {
                    self.scanning = false
                    self.message = "Original icons are not all accessible/visible. Refresh or remove unavailable selections. Nothing was hidden."
                    self.onChange?(); return
                }
                self.items = before
                // Bundle-level behavior is explicit, including all independently discovered icons of an owner.
                let actualSelection = before.filter { bundles.contains($0.identity.bundleID) }.map(\.identity)
                let savedIDs = Set(self.selected.map(\.id))
                self.selected = self.selected.compactMap { saved in actualSelection.first { $0.id == saved.id } }
                    + actualSelection.filter { !savedIDs.contains($0.id) }
                self.persist()
                self.message = "Applying experimental hiding…"
                self.onChange?()
                self.menuHelper.hide(bundleIDs: bundles.sorted(), visibleBundleIDs: found.sorted()) { [weak self] result in
                    guard let self, generation == self.visibilityGeneration else { return }
                    if case .failure(let error) = result {
                        self.scanning = false
                        self.revealAll()
                        self.message = error.localizedDescription
                        self.onChange?(); return
                    }
                    self.discoveryQueue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        let after = MenuBarItemDiscovery.scan().filter { item in screens.contains { $0.intersects(item.frame) } }
                        DispatchQueue.main.async {
                            guard let self, generation == self.visibilityGeneration else { return }
                            self.scanning = false
                            let preserved = Set(before.filter { !bundles.contains($0.identity.bundleID) }.map(\.identity.id))
                            let afterIDs = Set(after.map(\.identity.id))
                            let originalsRemain = after.contains { bundles.contains($0.identity.bundleID) }
                            let sourcesRunning = bundles.allSatisfy {
                                NSRunningApplication.runningApplications(withBundleIdentifier: $0).contains { !$0.isTerminated }
                            }
                            if self.hasPermission && sourcesRunning && !originalsRemain && preserved.isSubset(of: afterIDs) {
                                self.isHidden = true
                                self.message = "Hidden · verified originals removed; other icons preserved. Experimental helper active."
                                self.startSafetyChecks()
                            } else {
                                self.revealAll()
                                self.message = "Visibility check failed. Restriction released; originals restored."
                            }
                            self.onChange?()
                        }
                    }
                }
            }
        }
    }
}

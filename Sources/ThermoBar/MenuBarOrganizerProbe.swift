import AppKit
import ApplicationServices

/// Opt-in probe: creates/removes only its own test status items, never moves another app's icons.
enum MenuBarOrganizerProbe {
    /// Opt-in end-to-end check of already selected owners, real visibility, and child crash recovery.
    static func runIsolationCheck(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let manager = MenuBarOrganizer()
        let before = MenuBarItemDiscovery.scan()
        let targets = Set(manager.selected.map(\.bundleID))
        var hiddenSnapshot: [DiscoveredMenuBarItem] = []
        var testingCrash = false
        var finishing = false
        func snapshot(_ items: [DiscoveredMenuBarItem]) -> [[String: Any]] {
            items.map { ["bundleID": $0.identity.bundleID, "id": $0.identity.id,
                         "x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width] }
        }
        func finish(_ reason: String) {
            guard !finishing else { return }
            finishing = true
            manager.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let after = MenuBarItemDiscovery.scan()
                let restored = targets.isSubset(of: Set(after.map { $0.identity.bundleID }))
                let preserved = Set(before.filter { !targets.contains($0.identity.bundleID) }.map(\.identity.id))
                    .isSubset(of: Set(after.map(\.identity.id)))
                let payload: [String: Any] = ["accessibility": AXIsProcessTrusted(), "message": reason,
                    "hiddenVerified": testingCrash, "helperCrashRecovered": testingCrash && restored && preserved,
                    "before": snapshot(before), "hidden": snapshot(hiddenSnapshot), "restored": snapshot(after)]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                exit(testingCrash && restored && preserved ? 0 : 2)
            }
        }
        manager.onChange = {
            guard !finishing else { return }
            if manager.isHidden && !testingCrash {
                hiddenSnapshot = MenuBarItemDiscovery.scan()
                testingCrash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { manager.crashHelperForIsolationCheck() }
            } else if !manager.scanning && !manager.isHidden {
                finish(manager.message)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { finish("Isolation check deadline reached.") }
        manager.hideVerifiedPlacement()
        RunLoop.main.run()
    }

    /// Read-only snapshot for GUI-launched diagnostics (so the real app's TCC identity is used).
    static func writeDiagnostics(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let discovered = MenuBarItemDiscovery.scan()
        let payload: [String: Any] = [
            "accessibility": AXIsProcessTrusted(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "items": discovered.map { item -> [String: Any] in
                ["id": item.identity.id, "bundleID": item.identity.bundleID, "name": item.identity.name,
                 "x": item.frame.minX, "y": item.frame.minY, "width": item.frame.width, "height": item.frame.height,
                 "supported": item.supported]
            },
            "selected": (UserDefaults.standard.data(forKey: "ThermoBar.HiddenItems.v1").flatMap {
                try? JSONDecoder().decode([MenuBarItemIdentity].self, from: $0)
            } ?? []).map { ["id": $0.id, "bundleID": $0.bundleID, "name": $0.name] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        func settle() {
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                app.updateWindows()
            }
        }
        print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("accessibility=\(AXIsProcessTrusted())")
        let bar = NSStatusBar.system
        func buttonFrame(_ item: NSStatusItem) -> NSRect? {
            guard let button = item.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let samples = ["TB Test A", "TB Test B", "TB Test C"].map { title -> NSStatusItem in
            let item = bar.statusItem(withLength: 60)
            item.button?.title = title
            return item
        }
        defer { samples.forEach(bar.removeStatusItem) }
        settle()
        let sorted = samples.sorted { (buttonFrame($0)?.minX ?? 0) < (buttonFrame($1)?.minX ?? 0) }
        guard let left = sorted.first, let divider = sorted.dropFirst().first,
              let leftFrame = buttonFrame(left),
              let dividerFrame = buttonFrame(divider),
              let screen = NSScreen.screens.first, NSScreen.screens.count == 1 else {
            print("separator_test=unavailable (requires GUI and single display)"); return
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let foreignLeft = windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  (info[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.maxX <= dividerFrame.minX && rect.minX >= screen.frame.minX
        }
        guard !foreignLeft else { print("separator_test=skipped (would affect other applications)"); return }
        divider.length = 10_000
        divider.button?.title = ""
        settle()
        let hidden = buttonFrame(left)?.intersects(screen.frame) == false
        print("test_item_before=\(leftFrame)")
        print("test_item_hidden=\(hidden) frame=\(String(describing: buttonFrame(left)))")
        print("divider_length=\(divider.length) frame=\(String(describing: divider.button?.window?.frame))")
        divider.length = 60
        settle()
        print("test_item_restored=\(buttonFrame(left)?.intersects(screen.frame) == true)")
        print("external_command_drag=not_tested; AX activation=not_tested")
    }
}

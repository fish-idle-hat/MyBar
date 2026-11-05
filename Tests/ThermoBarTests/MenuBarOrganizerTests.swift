import AppKit
import ApplicationServices
import XCTest
@testable import ThermoBar

final class MenuBarOrganizerTests: XCTestCase {
    private func item(_ id: String, supported: Bool = true) -> DiscoveredMenuBarItem {
        DiscoveredMenuBarItem(identity: MenuBarItemIdentity(id: id, name: "Utility \(id)",
            bundleID: "example.\(id)", applicationPath: "/Applications/Utility.app"),
            element: AXUIElementCreateApplication(getpid()), frame: .zero, windowID: nil, supported: supported)
    }

    @MainActor
    func testSelectionOrderRestoresButNeverAutomaticallyHides() throws {
        let suite = "ThermoBarTests.Organizer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MenuBarOrganizer(defaults: defaults)
        manager.select(item("a"), enabled: true)
        manager.select(item("b"), enabled: true)
        manager.select(item("system", supported: false), enabled: true)
        manager.reorder(id: "b", before: "a")
        XCTAssertEqual(manager.selected.map(\.id), ["b", "a"])
        manager.reorder(id: "b", before: "")
        XCTAssertEqual(manager.selected.map(\.id), ["a", "b"])
        let restored = MenuBarOrganizer(defaults: defaults)
        XCTAssertEqual(restored.selected.map(\.id), ["a", "b"])
        XCTAssertFalse(restored.isHidden)
        XCTAssertTrue(restored.hiddenItems.isEmpty, "Selected-but-visible icons must not masquerade as hidden icons")
        XCTAssertEqual(restored.collectionSummary, "2 selected · Not hidden")
        restored.hideVerifiedPlacement()
        XCTAssertFalse(restored.isHidden, "Missing divider/geometry must never be treated as successful hiding")
        restored.restore(id: "a")
        XCTAssertEqual(restored.selected.map(\.id), ["b"])
        restored.restoreAll()
        XCTAssertTrue(restored.selected.isEmpty)
        XCTAssertFalse(restored.isHidden)
        XCTAssertEqual(restored.collectionSummary, "Organize menu bar icons")
    }

    @MainActor
    func testVisibleSelectionIsClearlyLabeledInHeader() throws {
        let suite = "ThermoBarTests.OrganizerVisible.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MenuBarOrganizer(defaults: defaults)
        manager.select(item("a"), enabled: true)
        let row = HiddenItemsRow(manager: manager)
        row.reload()
        XCTAssertTrue(row.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue == "1 selected · Not hidden"
        })
        XCTAssertTrue(row.subviews.compactMap { $0 as? NSScrollView }.allSatisfy(\.isHidden))
        if !manager.supportsWindowVerifiedHiding {
            manager.preparePlacement()
            manager.hideVerifiedPlacement()
            XCTAssertFalse(manager.isHidden)
            XCTAssertFalse(manager.message.isEmpty)
        }
    }

    @MainActor
    func testOrganizerAddsCompactRowWithoutChangingTabCoordinates() throws {
        let suite = "ThermoBarTests.OrganizerUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MenuBarOrganizer(defaults: defaults)
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        let host = OrganizerHostView(details: details, manager: manager)
        XCTAssertEqual(host.frame.height, SystemDetailsView.systemSectionHeight + 30)
        XCTAssertEqual(details.frame.height, SystemDetailsView.systemSectionHeight)
        XCTAssertEqual(details.frame.minY, 30)
        details.selectTab(at: 2)
        details.resizeSelectedSection(to: 410)
        host.resizeForDetails()
        XCTAssertEqual(host.frame.height, 440)
        if let path = ProcessInfo.processInfo.environment["THERMOBAR_ORGANIZER_PREVIEW"] {
            let panel = HiddenItemsManagementView(manager: manager)
            panel.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: panel.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = panel
            panel.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            details.selectTab(at: 0)
            host.resizeForDetails()
            let hostWindow = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            hostWindow.contentView = host
            host.appearance = NSAppearance(named: .aqua)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            host.layoutSubtreeIfNeeded()
            let hostBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: hostBitmap)
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("header.png")
            try XCTUnwrap(hostBitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }
}

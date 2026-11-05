import AppKit
import XCTest
@testable import ThermoBar

final class BrandingTests: XCTestCase {
    func testMyBarNamePreservesExistingApplicationIdentity() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "MyBar")
        XCTAssertEqual(info["CFBundleName"] as? String, "MyBar")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "local.thermobar.app")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "ThermoBar")
        XCTAssertTrue((info["NSAudioCaptureUsageDescription"] as? String)?.hasPrefix("MyBar ") == true)
        XCTAssertTrue((info["NSAppleEventsUsageDescription"] as? String)?.hasPrefix("MyBar ") == true)
    }

    @MainActor
    func testDetailsAccessibilityUsesMyBarName() {
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        XCTAssertEqual(details.accessibilityLabel(), "MyBar system details")
    }

    func testIconCatalogHasAllRequiredSizesAndTransparentCorners() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let catalog = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        let data = try Data(contentsOf: catalog.appendingPathComponent("Contents.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: String]])
        XCTAssertEqual(images.count, 10)
        for image in images {
            let filename = try XCTUnwrap(image["filename"])
            let size = try XCTUnwrap(image["size"]?.split(separator: "x").first.flatMap { Int($0) })
            let scale = try XCTUnwrap(image["scale"].flatMap { Int($0.dropLast()) })
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: catalog.appendingPathComponent(filename))))
            XCTAssertEqual(bitmap.pixelsWide, size * scale, filename)
            XCTAssertEqual(bitmap.pixelsHigh, size * scale, filename)
            XCTAssertTrue(bitmap.hasAlpha, filename)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        }
    }
}

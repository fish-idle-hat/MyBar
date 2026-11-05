import AppKit
import QuartzCore
import XCTest
@testable import ThermoBar

final class HoverSegmentedControlTests: XCTestCase {
    @MainActor private func control(_ labels: [String] = ["Overview", "Insights"]) -> HoverSegmentedControl {
        let control = HoverSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        control.frame = NSRect(x: 0, y: 0, width: 336, height: 25)
        control.selectedSegment = 0
        return control
    }
    @MainActor private func highlight(_ control: HoverSegmentedControl) throws -> CALayer {
        try XCTUnwrap(control.layer?.sublayers?.first { $0.name == "MyBar.segmentHover" })
    }
    @MainActor
    func testHoverDoesNotChangeSelectionOrBlockNativeHitTesting() throws {
        let control = control()
        let parent = NSView(frame: control.bounds); parent.addSubview(control)
        let highlight = try highlight(control)
        XCTAssertNil(control.hoveredSegment); XCTAssertEqual(highlight.opacity, 0)
        control.updateHover(at: NSPoint(x: 250, y: 12), animated: false)
        XCTAssertEqual(control.hoveredSegment, 1)
        XCTAssertEqual(control.selectedSegment, 0, "Hover must never select a category")
        XCTAssertEqual(highlight.opacity, 1)
        XCTAssertTrue(control.bounds.contains(highlight.frame))
        XCTAssertTrue(parent.hitTest(NSPoint(x: 250, y: 12)) === control, "A CALayer overlay must not intercept clicks")
        control.updateHover(at: nil, animated: false)
        XCTAssertNil(control.hoveredSegment); XCTAssertEqual(highlight.opacity, 0)
    }
    @MainActor
    func testSameHoverStyleIsUsedBySystemMoodSectionsAndMoodRanges() throws {
        let system = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        let systemControl = try XCTUnwrap(system.subviews.compactMap { $0 as? HoverSegmentedControl }.first)
        XCTAssertEqual(systemControl.accessibilityLabel(), "System section")
        XCTAssertEqual(systemControl.segmentCount, 3)
        let mood = MoodCompassView(frame: NSRect(origin: .zero, size: MoodCompassView.preferredSize))
        let controls = descendants(mood).compactMap { $0 as? HoverSegmentedControl }
        XCTAssertEqual(controls.count, 2)
        XCTAssertTrue(controls.contains { $0.accessibilityLabel() == "Mood Compass sections" })
        mood.selectPage(0)
        for control in [systemControl] + controls {
            for index in 0..<control.segmentCount {
                let x = 2 + (control.bounds.width - 4) * (CGFloat(index) + 0.5) / CGFloat(control.segmentCount)
                control.updateHover(at: NSPoint(x: x, y: control.bounds.midY), animated: false)
                XCTAssertEqual(control.hoveredSegment, index)
                XCTAssertEqual(try highlight(control).opacity, 1)
            }
        }
    }
    @MainActor
    func testTransitionsAreBoundedAndReduceMotionHasNoAnimation() throws {
        let control = control(); control.reduceMotion = { false }
        let highlight = try highlight(control)
        control.updateHover(at: NSPoint(x: 40, y: 12))
        XCTAssertEqual(highlight.animation(forKey: "hoverOpacity")?.duration, 0.12)
        control.updateHover(at: NSPoint(x: 250, y: 12))
        XCTAssertEqual(highlight.animation(forKey: "hoverPosition")?.duration, 0.14)
        for _ in 0..<100 { control.updateHover(at: NSPoint(x: 250, y: 12)) }
        XCTAssertLessThanOrEqual(highlight.animationKeys()?.count ?? 0, 2)
        control.reduceMotion = { true }
        control.updateHover(at: NSPoint(x: 40, y: 12))
        XCTAssertTrue(highlight.animationKeys()?.isEmpty ?? true)
        XCTAssertEqual(highlight.opacity, 1)
        control.updateHover(at: nil)
        XCTAssertEqual(highlight.opacity, 0)
        XCTAssertTrue(highlight.animationKeys()?.isEmpty ?? true)
    }
    @MainActor
    func testDisabledHiddenAndDetachedControlsClearHover() throws {
        let control = control()
        control.updateHover(at: NSPoint(x: 40, y: 12))
        control.isEnabled = false
        XCTAssertNil(control.hoveredSegment)
        XCTAssertEqual(try highlight(control).opacity, 0)
        control.isEnabled = true
        control.setEnabled(false, forSegment: 1)
        control.updateHover(at: NSPoint(x: 250, y: 12))
        XCTAssertNil(control.hoveredSegment)
        control.updateHover(at: NSPoint(x: 40, y: 12))
        control.isHidden = true; control.viewDidHide()
        XCTAssertNil(control.hoveredSegment)
        XCTAssertTrue(try highlight(control).animationKeys()?.isEmpty ?? true)
        control.isHidden = false
        control.updateHover(at: NSPoint(x: 40, y: 12))
        control.viewDidMoveToWindow()
        XCTAssertNil(control.hoveredSegment)
        XCTAssertEqual(try highlight(control).opacity, 0)
    }
    @MainActor
    func testTrackingAreaDoesNotAccumulateAcrossLayouts() {
        let control = control()
        for _ in 0..<100 { control.updateTrackingAreas() }
        XCTAssertEqual(control.trackingAreas.count, 1)
        XCTAssertTrue(control.trackingAreas[0].options.contains(.mouseMoved))
    }
    @MainActor
    func testHoverLayerRendersInBothAppearances() throws {
        let control = control(); control.reduceMotion = { true }
        let window = NSWindow(contentRect: control.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = control
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            control.appearance = NSAppearance(named: appearance)
            control.display()
            control.updateHover(at: nil, animated: false)
            let plain = try layerImage(control)
            control.updateHover(at: NSPoint(x: 250, y: 12), animated: false)
            XCTAssertEqual(try XCTUnwrap(highlight(control).backgroundColor).alpha, 0.10, accuracy: 0.001)
            let hovered = try layerImage(control)
            XCTAssertNotEqual(plain, hovered, "Hover must produce visible pixels, not only internal state")
            if ProcessInfo.processInfo.environment["MYBAR_HOVER_PREVIEW"] == "1" {
                try hovered.write(to: URL(fileURLWithPath: "/private/tmp/mybar-selector-hover-\(appearance.rawValue).png"))
            }
        }
    }
    @MainActor private func layerImage(_ control: HoverSegmentedControl) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(control.bounds.width * 2),
            pixelsHigh: Int(control.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image)?.cgContext)
        context.scaleBy(x: 2, y: 2)
        try XCTUnwrap(control.layer).render(in: context)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

import AppKit
import QuartzCore
import SQLite3
import XCTest
@testable import ThermoBar

final class PetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func marker(_ kind: String, date: Date? = nil) -> Data {
        let stamp = ISO8601DateFormatter().string(from: date ?? now)
        return Data("{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\"}}\n".utf8)
    }

    func testFanEffectUsesAnyPositiveValidRPMAndNeverTemperature() {
        XCTAssertFalse(PetActivity.fansAreSpinning([0, nil, .nan, -.infinity, -1]))
        XCTAssertTrue(PetActivity.fansAreSpinning([0, 1]))
        XCTAssertTrue(PetActivity.fansAreSpinning([1_000, 0]))
        XCTAssertFalse(PetActivity.fansAreSpinning([]))
    }
    func testTaskLifecycleHandlesSplitPacketsAndStaleSessions() {
        var cursor = PetCodexActivityReader.Cursor()
        let data = marker("task_started")
        cursor.consume(data.prefix(20), now: now)
        XCTAssertFalse(cursor.working)
        cursor.consume(data.dropFirst(20), now: now)
        XCTAssertTrue(cursor.working)
        cursor.consume(marker("task_complete"), now: now)
        XCTAssertFalse(cursor.working)
        cursor.consume(marker("token_count"), now: now)
        XCTAssertFalse(cursor.working, "Late usage metadata must not restart the pet's work animation")
        cursor.consume(marker("task_started"), now: now)
        cursor.consume(Data(), now: now.addingTimeInterval(1_801))
        XCTAssertFalse(cursor.working)
        cursor.consume(marker("task_started", date: now.addingTimeInterval(300)), now: now)
        XCTAssertFalse(cursor.working)
    }
    func testMalformedAndUnrelatedDataCannotTriggerWorkAndMemoryIsBounded() {
        var cursor = PetCodexActivityReader.Cursor()
        cursor.consume(Data("not json\n{\"type\":\"response_item\",\"payload\":{\"type\":\"task_started\"}}\n".utf8), now: now)
        XCTAssertFalse(cursor.working)
        cursor.consume(Data(repeating: 65, count: 200_000), now: now)
        XCTAssertTrue(cursor.remainder.isEmpty)
        cursor.consume(marker("task_started"), now: now)
        cursor.consume(marker("turn_aborted"), now: now)
        XCTAssertFalse(cursor.working)
    }
    func testIndexedReaderUsesIncrementalLocalRolloutsAndFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mybar-pet-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, updated_at INTEGER); CREATE INDEX idx_threads_updated_at ON threads(updated_at DESC);", nil, nil, nil), SQLITE_OK)
        let log = root.appendingPathComponent("sessions/rollout.jsonl")
        try marker("task_started").write(to: log)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(log.path)', \(Int(now.timeIntervalSince1970)));", nil, nil, nil), SQLITE_OK)
        let reader = PetCodexActivityReader(root: root)
        XCTAssertTrue(reader.read(now: now).working)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: marker("task_complete")); try handle.close()
        XCTAssertFalse(reader.read(now: now).working)
        XCTAssertTrue(reader.read(now: now).available)
        reader.clear()
        XCTAssertFalse(reader.read(now: now).working)
        let unavailable = PetCodexActivityReader(root: root.appendingPathComponent("missing")).read(now: now)
        XCTAssertFalse(unavailable.available); XCTAssertFalse(unavailable.working)
    }
    func testSettingsSanitizeAndWindowStaysOnConnectedScreens() {
        var settings = PetSettings()
        settings.scale = .nan; settings.x = .infinity; settings.y = 80
        settings.sanitize()
        XCTAssertEqual(settings.scale, 1.1); XCTAssertNil(settings.x); XCTAssertNil(settings.y)
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let origin = DesktopPetController.clampedOrigin(NSPoint(x: -30, y: 850), size: NSSize(width: 320, height: 240), screens: [screen])
        XCTAssertEqual(origin, NSPoint(x: -320, y: 660))
        XCTAssertFalse(PetSettings().enabled)
    }
    @MainActor
    func testPetHasDedicatedContinuousSizeSliderAndVisibilitySwitch() throws {
        let view = PetControlView(frame: NSRect(x: 0, y: 0, width: 360, height: PetControlView.preferredHeight))
        view.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(view.subviews.compactMap { $0 as? NSSlider }.first)
        let visibility = try XCTUnwrap(view.subviews.compactMap { $0 as? NSSwitch }.first)
        XCTAssertEqual(slider.accessibilityLabel(), "Pet size")
        XCTAssertTrue(slider.isContinuous)
        XCTAssertGreaterThan(slider.frame.width, 200)
        XCTAssertGreaterThan(slider.frame.minY, visibility.frame.maxY)
        var result: PetSettings?
        view.onSettingsChange = { result = $0 }
        slider.doubleValue = 1.4
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(result?.scale, 1.4)
        XCTAssertTrue(view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("140%"))
        visibility.state = .on
        XCTAssertTrue(visibility.sendAction(visibility.action, to: visibility.target))
        XCTAssertTrue(result?.enabled == true)
        visibility.state = .off
        XCTAssertTrue(visibility.sendAction(visibility.action, to: visibility.target))
        XCTAssertFalse(result?.enabled ?? true)
    }
    @MainActor
    func testMusicReactionRequiresActiveMusicAndRespectsOptOut() throws {
        let suite = "MyBarPetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DesktopPetController(defaults: defaults)
        var monitoringChanges = 0
        controller.onMonitoringChange = { monitoringChanges += 1 }
        var larger = controller.settings; larger.scale = 1.4
        controller.configure(larger)
        XCTAssertEqual(monitoringChanges, 0, "Size drags must not restart monitoring")
        var music = SoundPlaybackApp(processObjectID: 1, pid: 42, displayPID: 42, name: "Music",
            bundleIdentifier: "com.apple.Music", kind: .music, volume: 0.4, selectedOutputUID: nil, routeState: .system)
        controller.updateMusic(SoundControlSnapshot(apps: [music]))
        XCTAssertTrue(controller.displayedActivity.musicPlaying)
        music.playbackState = .paused
        controller.updateMusic(SoundControlSnapshot(apps: [music]))
        XCTAssertFalse(controller.displayedActivity.musicPlaying)
        music.playbackState = .playing
        controller.updateMusic(SoundControlSnapshot(apps: [music]))
        var settings = controller.settings; settings.music = false
        controller.configure(settings)
        XCTAssertFalse(controller.displayedActivity.musicPlaying)
        XCTAssertFalse(controller.needsMusicMonitoring)
        XCTAssertFalse(controller.settings.enabled)
    }
    @MainActor
    func testPetPageUsesSharedHoverAndDoesNotLeakIntoInsights() throws {
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        let pet = PetControlView(frame: .zero)
        details.installPetView(pet)
        let selector = try XCTUnwrap(details.subviews.compactMap { $0 as? HoverSegmentedControl }.first)
        XCTAssertEqual(selector.label(forSegment: 2), "Pet")
        details.selectSystemPage(at: 2); details.layoutSubtreeIfNeeded()
        XCTAssertTrue(details.isPetPageSelected); XCTAssertFalse(details.isInsightsTabSelected)
        XCTAssertFalse(pet.isHidden); XCTAssertTrue(details.bounds.contains(pet.frame))
        details.selectSystemPage(at: 1)
        XCTAssertTrue(details.isInsightsTabSelected); XCTAssertTrue(pet.isHidden)
        details.selectSystemPage(at: 0)
        XCTAssertEqual(details.frame.height, SystemDetailsView.systemSectionHeight)
    }
    @MainActor
    func testBundledAtlasAndCombinedEffectsStopWhenHiddenOrMotionReduced() throws {
        XCTAssertTrue(PetSpriteAtlas.shared.isAvailable)
        XCTAssertEqual(PetSpriteAtlas.shared.idle.first?.width, 110)
        let view = PetCanvasView(frame: NSRect(origin: .zero, size: PetCanvasView.canvasSize))
        let combined = PetActivity(codexWorking: true, codexAvailable: true, musicPlaying: true, fansSpinning: true)
        view.update(combined, active: true, reduceMotion: false)
        XCTAssertTrue(view.animationsActive)
        XCTAssertGreaterThan(animationCount(view.layer), 3)
        for _ in 0..<100 { view.update(combined, active: true, reduceMotion: false) }
        XCTAssertLessThan(animationCount(view.layer), 9)
        view.update(combined, active: true, reduceMotion: true)
        XCTAssertEqual(animationCount(view.layer), 0)
        view.update(combined, active: false, reduceMotion: false)
        XCTAssertFalse(view.animationsActive); XCTAssertEqual(animationCount(view.layer), 0)
    }
    @MainActor
    func testEveryPetStateRendersDistinctPixelsWithoutMovingWindow() throws {
        let view = PetCanvasView(frame: NSRect(origin: .zero, size: PetCanvasView.canvasSize))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let origin = window.frame.origin
        var images: [Data] = []
        for (name, state) in [("idle", PetActivity()), ("work", PetActivity(codexWorking: true)),
            ("music", PetActivity(musicPlaying: true)), ("fans", PetActivity(fansSpinning: true)),
            ("combined", PetActivity(codexWorking: true, musicPlaying: true, fansSpinning: true))] {
            view.update(state, active: true, reduceMotion: true)
            view.layoutSubtreeIfNeeded(); view.display()
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 2560,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            context.scaleBy(x: 2, y: 2); context.translateBy(x: 0, y: 240); context.scaleBy(x: 1, y: -1)
            view.layer?.render(in: context)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000)
            images.append(png)
            if ProcessInfo.processInfo.environment["MYBAR_PET_PREVIEW"] == "1" {
                try png.write(to: URL(fileURLWithPath: "/private/tmp/mybar-pet-\(name).png"))
            }
            XCTAssertEqual(window.frame.origin, origin)
        }
        XCTAssertEqual(Set(images).count, 5)
    }
    private func animationCount(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1) }
    }
}

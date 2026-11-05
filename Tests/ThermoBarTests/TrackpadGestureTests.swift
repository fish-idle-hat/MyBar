import AppKit
import XCTest
import TrackpadGestureCore
@testable import ThermoBar

final class TrackpadGestureTests: XCTestCase {
    private func contacts(_ x: Double = 0, _ y: Double = 0, count: Int = 4) -> [TrackpadContact] {
        (0..<count).map { TrackpadContact(id: $0, x: 0.25 + Double($0) * 0.12 + x, y: 0.4 + y) }
    }
    private func swipe(_ dx: Double, _ dy: Double = 0, sensitivity: SwipeSensitivity = .medium,
                       reverse: Bool = false) -> TabSwipe? {
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1)
        _ = r.update(contacts(), at: 1.1)
        _ = r.update(contacts(dx, dy), at: 1.2, sensitivity: sensitivity, reversed: reverse)
        return r.update([], at: 1.25, sensitivity: sensitivity, reversed: reverse)
    }
    func testLeftIsNextRightIsPreviousAndReverseIsExplicit() {
        XCTAssertEqual(swipe(-0.14), .next); XCTAssertEqual(swipe(0.14), .previous)
        XCTAssertEqual(swipe(-0.14, reverse: true), .previous)
        XCTAssertEqual(swipe(0.14, reverse: true), .next)
    }
    func testSensitivityThresholdsAndTaps() {
        XCTAssertNil(swipe(0)); XCTAssertNil(swipe(0.07, sensitivity: .high))
        XCTAssertEqual(swipe(0.09, sensitivity: .high), .previous)
        XCTAssertNil(swipe(0.11, sensitivity: .medium))
        XCTAssertEqual(swipe(0.13, sensitivity: .medium), .previous)
        XCTAssertNil(swipe(0.17, sensitivity: .low))
        XCTAssertEqual(swipe(0.19, sensitivity: .low), .previous)
    }
    func testVerticalAndDiagonalGesturesDoNotSwitch() {
        XCTAssertNil(swipe(0.02, 0.2))
        XCTAssertNil(swipe(0.13, 0.13))
        XCTAssertNil(swipe(0.13, 0.066))
    }
    func testOneTwoThreeAndFiveFingersNeverSwitch() {
        for count in [1, 2, 3, 5] {
            var r = FourFingerSwipeRecognizer()
            _ = r.update([], at: 1); _ = r.update(contacts(count: count), at: 1.1)
            _ = r.update(contacts(0.15, count: count), at: 1.2)
            XCTAssertNil(r.update([], at: 1.25))
        }
    }
    func testNeverFiresBeforeLiftAndOnePerGesture() {
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1); _ = r.update(contacts(), at: 1.1)
        for index in 1...5 { XCTAssertNil(r.update(contacts(Double(index) * -0.03), at: 1.1 + Double(index) * 0.03)) }
        XCTAssertEqual(r.update([], at: 1.3), .next)
        XCTAssertNil(r.update([], at: 1.31)); XCTAssertNil(r.update([], at: 1.4))
    }
    func testDebounceAfterLift() {
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1); _ = r.update(contacts(), at: 1.1)
        _ = r.update(contacts(-0.15), at: 1.2)
        XCTAssertEqual(r.update([], at: 1.25), .next)
        _ = r.update(contacts(), at: 1.3); _ = r.update(contacts(-0.15), at: 1.4)
        XCTAssertNil(r.update([], at: 1.45))
        _ = r.update(contacts(), at: 1.6); _ = r.update(contacts(0.15), at: 1.7)
        XCTAssertEqual(r.update([], at: 1.75), .previous)
    }
    func testIdentityReplacementAndFifthFingerCancelUntilFullLift() {
        for extra in [false, true] {
            var r = FourFingerSwipeRecognizer()
            _ = r.update([], at: 1); _ = r.update(contacts(), at: 1.1)
            var changed = contacts(0.15)
            if extra { changed.append(TrackpadContact(id: 9, x: 0.4, y: 0.4)) }
            else { changed[0] = TrackpadContact(id: 9, x: 0.4, y: 0.4) }
            _ = r.update(changed, at: 1.2); _ = r.update(contacts(0.18), at: 1.25)
            XCTAssertNil(r.update([], at: 1.3))
        }
    }
    func testPinchAndRotationAndOneMovingFingerCancel() {
        for positions in [
            [TrackpadContact(id: 0, x: 0.10, y: 0.4), TrackpadContact(id: 1, x: 0.47, y: 0.4), TrackpadContact(id: 2, x: 0.59, y: 0.4), TrackpadContact(id: 3, x: 0.8, y: 0.4)],
            [TrackpadContact(id: 0, x: 0.4, y: 0.55), TrackpadContact(id: 1, x: 0.52, y: 0.45), TrackpadContact(id: 2, x: 0.64, y: 0.35), TrackpadContact(id: 3, x: 0.76, y: 0.25)],
            [TrackpadContact(id: 0, x: 0.9, y: 0.4)] + Array(contacts().dropFirst())
        ] {
            var r = FourFingerSwipeRecognizer()
            _ = r.update([], at: 1); _ = r.update(contacts(), at: 1.1)
            _ = r.update(positions, at: 1.2); _ = r.update(contacts(0.15), at: 1.25)
            XCTAssertNil(r.update([], at: 1.3))
        }
    }
    func testNaturalFingerStaggerOnLandingAndLiftoff() {
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1); _ = r.update(contacts(count: 2), at: 1.05)
        _ = r.update(contacts(), at: 1.1); _ = r.update(contacts(-0.15), at: 1.2)
        _ = r.update(contacts(-0.15, count: 3), at: 1.22)
        _ = r.update(contacts(-0.15, count: 1), at: 1.24)
        XCTAssertEqual(r.update([], at: 1.26), .next)
    }
    func testReLandingSlowAssemblyTimeoutAndStaleFramesCancel() {
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1); _ = r.update(contacts(count: 2), at: 1.1)
        _ = r.update(contacts(), at: 1.4); _ = r.update(contacts(-0.15), at: 1.5)
        XCTAssertNil(r.update([], at: 1.6))
        _ = r.update(contacts(), at: 2); _ = r.update(contacts(-0.15), at: 2.1)
        _ = r.update(contacts(-0.15, count: 3), at: 2.12)
        _ = r.update(contacts(-0.16), at: 2.14)
        XCTAssertNil(r.update([], at: 2.2))
        _ = r.update(contacts(), at: 3); _ = r.update(contacts(-0.15), at: 3.1)
        XCTAssertNil(r.update([], at: 4))
    }
    func testEnablingMidGestureRequiresFullLift() {
        var r = FourFingerSwipeRecognizer()
        _ = r.update(contacts(), at: 1); _ = r.update(contacts(-0.15), at: 1.1)
        XCTAssertNil(r.update([], at: 1.2))
        _ = r.update(contacts(), at: 1.5); _ = r.update(contacts(-0.15), at: 1.6)
        r.cancel(); XCTAssertNil(r.update([], at: 1.7))
    }
    func testInvalidCoordinatesDuplicateIdentityAndTimeDoNotSwitch() {
        for value in [Double.nan, .infinity, -1, 2] {
            var r = FourFingerSwipeRecognizer()
            _ = r.update([], at: 1); _ = r.update(contacts(), at: 1.1)
            var bad = contacts(-0.15); bad[0] = TrackpadContact(id: 0, x: value, y: 0.4)
            _ = r.update(bad, at: 1.2); XCTAssertNil(r.update([], at: 1.25))
        }
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1)
        let duplicated = Array(repeating: TrackpadContact(id: 0, x: 0.5, y: 0.5), count: 4)
        XCTAssertNil(r.update(duplicated, at: 1.1)); XCTAssertNil(r.update([], at: .nan))
    }
    func testReturnToOriginIsNotCompletedSwipeAndVerticalExcursionStaysCancelled() {
        var r = FourFingerSwipeRecognizer()
        _ = r.update([], at: 1); _ = r.update(contacts(), at: 1.1)
        _ = r.update(contacts(-0.15), at: 1.2); _ = r.update(contacts(), at: 1.25)
        XCTAssertNil(r.update([], at: 1.3))
        _ = r.update(contacts(), at: 2); _ = r.update(contacts(0, 0.1), at: 2.1)
        _ = r.update(contacts(-0.15), at: 2.2); XCTAssertNil(r.update([], at: 2.25))
    }
    func testBrowserAllowlistAndNativeShortcutMapping() {
        XCTAssertEqual(GestureBrowser.allCases.count, 5)
        XCTAssertNil(GestureBrowser(rawValue: "com.apple.finder"))
        for browser in GestureBrowser.allCases {
            let next = browser.shortcut(.next), previous = browser.shortcut(.previous)
            if browser == .safari {
                XCTAssertEqual(next.key, 48); XCTAssertEqual(next.flags, .maskControl)
                XCTAssertEqual(previous.flags, [.maskControl, .maskShift])
            } else {
                XCTAssertEqual(next.key, 124); XCTAssertEqual(previous.key, 123)
                XCTAssertEqual(next.flags, [.maskCommand, .maskAlternate])
            }
            XCTAssertFalse(next.flags == .maskCommand && next.key == 48, "Never Command-Tab")
        }
    }
    func testPermissionFocusAndSecureInputGatesNeverPost() {
        let target = GestureForeground(pid: 123, browser: .chrome)
        var count = 0
        XCTAssertFalse(BrowserTabDispatcher.send(.next, to: target, frontmost: { nil }, allowed: { true }, post: { _, _ in count += 1 }))
        XCTAssertFalse(BrowserTabDispatcher.send(.next, to: target, frontmost: { target }, allowed: { false }, post: { _, _ in count += 1 }))
        XCTAssertFalse(BrowserTabDispatcher.send(.next, to: target, frontmost: { target }, allowed: { true }, secureInput: { true }, post: { _, _ in count += 1 }))
        XCTAssertFalse(BrowserTabDispatcher.send(.next, to: target, frontmost: { target }, allowed: { true }, secureInput: { false }, modifiers: { .maskCommand }, post: { _, _ in count += 1 }))
        XCTAssertEqual(count, 0)
    }
    func testDispatcherUsesOnlyTargetPIDAndBalancedKeyPair() {
        let target = GestureForeground(pid: 456, browser: .firefox)
        var events: [(CGEventType, Int64, CGEventFlags, pid_t)] = []
        XCTAssertTrue(BrowserTabDispatcher.send(.previous, to: target, frontmost: { target }, allowed: { true }, secureInput: { false }, modifiers: { [] }, post: { event, pid in
            events.append((event.type, event.getIntegerValueField(.keyboardEventKeycode), event.flags, pid))
        }))
        XCTAssertEqual(events.count, 2)
        guard events.count == 2 else { return }
        XCTAssertEqual(events[0].0, .keyDown); XCTAssertEqual(events[1].0, .keyUp)
        XCTAssertEqual(events[0].1, 123); XCTAssertEqual(events[1].1, 123)
        XCTAssertTrue(events.allSatisfy { $0.2 == [.maskCommand, .maskAlternate] && $0.3 == target.pid })
    }
    func testFocusChangesDuringDispatchCancelInsteadOfActivatingBrowser() {
        let target = GestureForeground(pid: 456, browser: .firefox)
        var queries = 0, posts = 0
        XCTAssertFalse(BrowserTabDispatcher.send(.next, to: target, frontmost: {
            queries += 1; return queries == 1 ? target : nil
        }, allowed: { true }, secureInput: { false }, modifiers: { [] }, post: { _, _ in posts += 1 }))
        XCTAssertEqual(posts, 0)
    }
    func testDelayedDuplicatedDisabledOrOldGenerationMessagesAreDiscarded() {
        var gate = GestureDispatchGate()
        let id = UUID().uuidString
        let reply = TrackpadReply(.swipe, generation: id, direction: .next, uptime: 10)
        XCTAssertFalse(gate.accept(reply, generation: "other", enabled: true, now: 10.1))
        XCTAssertFalse(gate.accept(reply, generation: id, enabled: false, now: 10.1))
        XCTAssertFalse(gate.accept(reply, generation: id, enabled: true, now: 11))
        XCTAssertTrue(gate.accept(reply, generation: id, enabled: true, now: 10.1))
        XCTAssertFalse(gate.accept(reply, generation: id, enabled: true, now: 10.2))
    }
    func testSystemConflictIsReadOnlyConservativeAndCoversBluetooth() {
        XCTAssertEqual(TrackpadSystemConflict.classify([.clear, .unknown, .clear]), .clear)
        XCTAssertEqual(TrackpadSystemConflict.classify([.clear, .reserved, .clear]), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.classify([.clear, .unknown, .reserved]), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.classify([.unknown, .unknown, .unknown]), .unknown)
        XCTAssertEqual(TrackpadSystemConflict.classify([.clear, .unknown, .unknown]), .unknown)
        XCTAssertEqual(TrackpadSystemConflict.classify([.unknown, .clear, .unknown]), .unknown)
        XCTAssertEqual(TrackpadSystemConflict.classify([.clear, .clear, .unknown]), .clear)
    }
    func testThreeFingerSelectionDoesNotCancelAnEnabledFourFingerMapping() {
        let threeFinger = TrackpadSystemConflict.selection(three: 2, four: 2)
        XCTAssertEqual(threeFinger, .reserved, "Physical swipes still switch desktops with both mappings enabled")
        XCTAssertEqual(TrackpadSystemConflict.classify([threeFinger, threeFinger, threeFinger]), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: 0, four: 2), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: 1, four: 2), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: nil, four: 2), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: 2, four: nil), .unknown)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: nil, four: 0), .clear)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: 2, four: 1), .reserved)
        XCTAssertEqual(TrackpadSystemConflict.selection(three: 2, four: 99), .unknown)
    }
    func testBoundedPipeRejectsOversizedAndHandlesSplitMessages() throws {
        var buffer = GestureLineBuffer()
        let command = TrackpadCommand(generation: UUID().uuidString, active: false, settings: TrackpadGestureSettings())
        var data = try JSONEncoder().encode(command); data.append(10)
        XCTAssertTrue(try buffer.consume(data.prefix(10)).isEmpty)
        let lines = try buffer.consume(data.dropFirst(10))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(TrackpadCommand.self, from: lines[0]).generation, command.generation)
        XCTAssertThrowsError(try buffer.consume(Data(repeating: 65, count: 1_025)))
    }
    func testSettingsDefaultOffRoundTripAndCorruptionDoesNotEnableMonitoring() throws {
        let suite = "MyBar.GestureTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(TrackpadGestureManager(defaults: defaults).settings.enabled)
        var settings = TrackpadGestureSettings(); settings.enabled = true; settings.sensitivity = .high; settings.reversed = true
        defaults.set(try JSONEncoder().encode(settings), forKey: TrackpadGestureManager.settingsKey)
        XCTAssertEqual(TrackpadGestureManager(defaults: defaults).settings, settings)
        defaults.set(Data("invalid".utf8), forKey: TrackpadGestureManager.settingsKey)
        XCTAssertFalse(TrackpadGestureManager(defaults: defaults).settings.enabled)
    }
    @MainActor
    func testHelperExitAndMalformedReplyFailWithoutAffectingHost() async throws {
        for script in ["#!/bin/sh\nexit 7\n", "#!/bin/sh\nprintf 'invalid-json\\n'\n"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mybar-gesture-failure-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("helper")
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = TrackpadHelperClient(url: executable)
            let failed = expectation(description: "Helper failure isolated")
            var replies = 0
            client.onReply = { _ in replies += 1 }
            client.onFailure = { failed.fulfill() }
            try client.start()
            await fulfillment(of: [failed], timeout: 3)
            client.stop()
            XCTAssertEqual(replies, 0)
        }
    }
    @MainActor
    func testSettingsUIFitsInBothAppearancesAndToggleDoesNotRunService() throws {
        _ = NSApplication.shared
        let view = TrackpadGesturesSettingsView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        var changes = 0
        view.onSettings = { _ in changes += 1 }
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            view.update(TrackpadGestureSettings(), status: "Off · no trackpad monitoring", permissionNeeded: false)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.display()
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if ProcessInfo.processInfo.environment["TRACKPAD_PREVIEW"] == "1" {
                try data.write(to: URL(fileURLWithPath: "/private/tmp/mybar-trackpad-\(appearance.rawValue).png"))
            }
            for label in all(view).compactMap({ $0 as? NSTextField }) where !label.isHidden {
                let rect = label.convert(label.bounds, to: view)
                XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(rect), label.stringValue)
            }
        }
        let toggle = try XCTUnwrap(all(view).compactMap { $0 as? NSSwitch }.first)
        toggle.performClick(nil)
        XCTAssertEqual(changes, 1)
    }
    @MainActor
    func testDisablingTerminatesOnlyOwnedUnresponsiveHelper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mybar-gesture-hang-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("helper")
        let script = "#!/bin/sh\ntrap '' TERM\nprintf '{\"version\":1,\"kind\":\"ready\",\"generation\":\"\"}\\n'\nexec /bin/sleep 30\n"
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let client = TrackpadHelperClient(url: file)
        let ready = expectation(description: "Fixture ready")
        client.onReply = { if $0.kind == .ready { ready.fulfill() } }
        try client.start()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(client.isRunning)
        client.stop()
        try await Task.sleep(nanoseconds: 3_300_000_000)
        XCTAssertFalse(client.isRunning, "An unresponsive owned helper cannot survive Disable")
    }
    @MainActor
    func testRealHelperBidirectionalShortMessagesWithoutTouchMonitoring() async throws {
        let executable = Bundle(for: TrackpadGestureTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MyBarTrackpadHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let client = TrackpadHelperClient(url: executable, arguments: ["--ipc-test"])
        let generation = UUID().uuidString
        let completed = expectation(description: "Small command/reply without waiting for pipe EOF")
        var began = 0.0
        client.onFailure = { XCTFail("Real helper pipe failed") }
        client.onReply = { reply in
            if reply.kind == .ready {
                began = ProcessInfo.processInfo.systemUptime
                client.send(TrackpadCommand(generation: generation, active: false, settings: TrackpadGestureSettings()))
            } else if reply.kind == .devices {
                XCTAssertEqual(reply.generation, generation); XCTAssertEqual(reply.deviceCount, 0)
                print(String(format: "TRACKPAD_IPC_BENCHMARK|inactive command + reply %.3f ms|no touch monitoring", (ProcessInfo.processInfo.systemUptime - began) * 1_000))
                completed.fulfill()
            }
        }
        defer { client.onReply = nil; client.stop() }
        try client.start()
        await fulfillment(of: [completed], timeout: 2)
    }
    func testCallbackLogicBenchmark() {
        let begin = ProcessInfo.processInfo.systemUptime
        var r = FourFingerSwipeRecognizer()
        let points = contacts(count: 2)
        for index in 0..<100_000 { _ = r.update(points, at: Double(index) * 0.01) }
        let microseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1_000_000 / 100_000
        print(String(format: "TRACKPAD_BENCHMARK|two-contact frame %.3f microseconds|100000 frames|no main dispatch", microseconds))
        XCTAssertLessThan(microseconds, 100)
    }
    func testFourContactRecognitionBenchmark() {
        let begin = ProcessInfo.processInfo.systemUptime
        let origin = contacts(), moved = contacts(-0.14)
        var recognizer = FourFingerSwipeRecognizer(), completed = 0
        for index in 0..<10_000 {
            let time = Double(index)
            _ = recognizer.update([], at: time)
            _ = recognizer.update(origin, at: time + 0.1)
            _ = recognizer.update(moved, at: time + 0.2)
            if recognizer.update([], at: time + 0.25) == .next { completed += 1 }
        }
        XCTAssertEqual(completed, 10_000)
        let microseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1_000_000 / 40_000
        print(String(format: "TRACKPAD_BENCHMARK|four-contact stroke average frame %.3f microseconds|40000 frames", microseconds))
        XCTAssertLessThan(microseconds, 100)
    }
}

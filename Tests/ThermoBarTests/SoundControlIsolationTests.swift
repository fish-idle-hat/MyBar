import CoreAudio
import XCTest
@testable import ThermoBar

final class SoundControlIsolationTests: XCTestCase {
    func testPlaybackWorkerTimesOutInsteadOfBlockingFutureCommands() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let start = Date()
        XCTAssertEqual(PlaybackCommandRunner.execute(process, timeout: 0.05), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let next = Process(); next.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertEqual(PlaybackCommandRunner.execute(next, timeout: 1), .success)
    }
    func testPlaybackRejectsMalformedBundleIdentifier() {
        XCTAssertEqual(PlaybackCommandRunner.toggle(bundleIdentifier: "bad\"\\identifier"), .unsupported)
    }

    func testOversizedHelperResponseIsRejectedWithoutGrowingHostBuffer() throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("mybar-oversized-helper-\(UUID())")
        try "#!/bin/sh\nprintf '%05000d' 0\nwhile read line; do [ \"$line\" = stop ] && exit 0; done\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: helper) }
        let rejected = expectation(description: "invalid helper response rejected")
        let route = try IsolatedAudioRoute(processID: 1, outputUID: "test-output", volume: 0.4,
            onEvent: { if $0 == .failed("Invalid audio helper response") { rejected.fulfill() } }, helperURL: helper)
        wait(for: [rejected], timeout: 2)
        route.stop()
    }

    @MainActor
    func testPetPlaybackProbeDoesNotPublishOrMutateSoundControls() async throws {
        let suite = "MyBarTests.PetAudioIsolation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SoundControlManager(defaults: defaults)
        manager.setPermanent(SoundPermanentMedia(bundleIdentifier: "com.apple.Music", name: "Music", kind: .music), enabled: true)
        let before = defaults.data(forKey: "ThermoBar.SoundPermanentMedia.v1")
        var snapshots = 0
        manager.onSnapshotChange = { _ in snapshots += 1 }
        let completed = expectation(description: "read-only playback probe")
        manager.refreshMusicActivity { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(defaults.data(forKey: "ThermoBar.SoundPermanentMedia.v1"), before)
    }

    func testMutedSpeakerUnmutesWithoutChangingVolume() {
        var controls: [AudioObjectPropertyElement: UInt32] = [0: 1]
        var writes: [AudioObjectPropertyElement] = []
        XCTAssertTrue(SoundOutputMuteControl.unmute(read: { controls[$0] }, write: { element, value in
            writes.append(element)
            controls[element] = value
            return true
        }))
        XCTAssertEqual(writes, [0])
        XCTAssertEqual(controls[0], 0)
    }

    func testChannelMuteIsClearedButUnsupportedControlsAreUntouched() {
        var controls: [AudioObjectPropertyElement: UInt32] = [1: 1, 2: 1]
        XCTAssertTrue(SoundOutputMuteControl.unmute(read: { controls[$0] }, write: { element, value in
            controls[element] = value
            return true
        }))
        XCTAssertEqual(controls, [1: 0, 2: 0])
        XCTAssertTrue(SoundOutputMuteControl.unmute(read: { _ in nil }, write: { _, _ in
            XCTFail("A nonexistent mute control must not be written")
            return false
        }))
    }

    func testMuteWriteMustActuallyTakeEffect() {
        XCTAssertFalse(SoundOutputMuteControl.unmute(read: { $0 == 0 ? 1 : nil }, write: { _, _ in true }))
        XCTAssertFalse(SoundOutputMuteControl.unmute(read: { $0 == 0 ? 1 : nil }, write: { _, _ in false }))
    }

    func testMutedAndZeroVolumeOutputsHaveHonestStatus() {
        var device = SoundOutputDevice(id: 78, uid: "speakers", name: "Speakers", isDefault: false,
                                      volume: 0.3125, isMuted: true)
        XCTAssertEqual(device.silenceWarning, "Output muted")
        device.isMuted = false
        XCTAssertNil(device.silenceWarning)
        XCTAssertEqual(SoundOutputDevice(id: 78, uid: "speakers", name: "Speakers", isDefault: false,
                                        volume: 0).silenceWarning, "Device volume is 0%")
    }

    @MainActor
    func testAudioSceneRejectsDisconnectedOutputBeforeChangingPins() throws {
        let suite = "ThermoBarTests.SceneOutput.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = AudioScene(name: "Headphones", apps: [], permanent: [],
                               deviceUID: "disconnected-headphones", deviceVolume: 0.4)
        defaults.set(try JSONEncoder().encode([scene]), forKey: "ThermoBar.AudioScenes.v1")
        let manager = SoundControlManager(defaults: defaults)
        let music = SoundPermanentMedia(bundleIdentifier: "com.apple.Music", name: "Music", kind: .music)
        manager.setPermanent(music, enabled: true)
        var result: SoundControlSnapshot?
        manager.onSnapshotChange = { result = $0 }
        manager.applyScene(named: "Headphones")
        XCTAssertEqual(result?.permanentMedia, [music])
        XCTAssertTrue(result?.message.contains("reconnect") == true)
    }

    @MainActor
    func testAudioScenePersistsAndRestoresPinnedMedia() throws {
        let suite = "ThermoBarTests.Scenes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SoundControlManager(defaults: defaults)
        let music = SoundPermanentMedia(bundleIdentifier: "com.apple.Music", name: "Music", kind: .music)
        manager.setPermanent(music, enabled: true)
        manager.saveScene(named: "Study")
        manager.setPermanent(music, enabled: false)
        let restored = SoundControlManager(defaults: defaults)
        XCTAssertEqual(restored.savedScenes.map(\.name), ["Study"])
        var result: SoundControlSnapshot?
        restored.onSnapshotChange = { result = $0 }
        restored.applyScene(named: "Study")
        XCTAssertEqual(result?.permanentMedia, [music])
    }

    @MainActor
    func testMasterPlaybackPublishesImmediateStateThenConfirmation() async throws {
        let suite = "ThermoBarTests.SoundPlayback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SoundControlManager(defaults: defaults, playbackCommand: { _ in .success })
        let music = SoundPermanentMedia(bundleIdentifier: "com.apple.Music", name: "Music", kind: .music)
        var states: [SoundPlaybackState] = []
        let confirmed = expectation(description: "playback confirmed")
        var didConfirm = false
        manager.onSnapshotChange = { snapshot in
            guard let state = snapshot.apps.first?.playbackState else { return }
            states.append(state)
            if state == .playing, !didConfirm {
                didConfirm = true
                confirmed.fulfill()
            }
        }

        manager.setPermanent(music, enabled: true)
        XCTAssertEqual(states.last, .paused)
        manager.toggleMasterPlayback()
        XCTAssertEqual(states.last, .starting)
        await fulfillment(of: [confirmed], timeout: 1)
        XCTAssertTrue(states.contains(.starting))
        XCTAssertEqual(states.last, .playing)
    }

    func testPlaybackCommandRejectsMissingApplicationWithoutLaunchingAnything() {
        XCTAssertEqual(
            PlaybackCommandRunner.toggle(bundleIdentifier: "invalid.thermobar.missing.\(UUID().uuidString)"),
            .notInstalled
        )
    }

    @MainActor
    func testPermanentMediaPersistsAndCanBeReordered() throws {
        let suite = "ThermoBarTests.SoundMedia.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let music = SoundPermanentMedia(bundleIdentifier: "com.apple.Music", name: "Music", kind: .music)
        let browser = SoundPermanentMedia(bundleIdentifier: "com.example.Browser", name: "Browser", kind: .video)

        let firstManager = SoundControlManager(defaults: defaults)
        firstManager.setPermanent(music, enabled: true)
        firstManager.setPermanent(browser, enabled: true)

        let restoredManager = SoundControlManager(defaults: defaults)
        var snapshot: SoundControlSnapshot?
        restoredManager.onSnapshotChange = { snapshot = $0 }
        restoredManager.movePermanent(bundleIdentifier: browser.bundleIdentifier, direction: -1)

        XCTAssertEqual(snapshot?.permanentMedia, [browser, music])
        XCTAssertEqual(snapshot?.apps.map(\.name), ["Browser", "Music"])
        XCTAssertTrue(snapshot?.apps.allSatisfy { !$0.isActive && $0.isPermanent } == true)
    }

    func testDormantVirtualOutputIsHiddenUntilItIsActive() {
        XCTAssertFalse(SoundOutputDeviceVisibility.shouldShow(
            isAlive: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeVirtual,
            isRunning: false
        ))
        XCTAssertTrue(SoundOutputDeviceVisibility.shouldShow(
            isAlive: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeVirtual,
            isRunning: true
        ))
    }

    func testAvailablePhysicalOutputRemainsVisibleWhenIdle() {
        XCTAssertTrue(SoundOutputDeviceVisibility.shouldShow(
            isAlive: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeBuiltIn,
            isRunning: false
        ))
        XCTAssertFalse(SoundOutputDeviceVisibility.shouldShow(
            isAlive: false,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeBuiltIn,
            isRunning: false
        ))
    }

    func testAudioHelperProcessResolvesToBrowserOwner() {
        let parents: [pid_t: pid_t] = [1432: 702, 702: 1]
        let owner = AudioProcessOwnership.ownerPID(
            startingAt: 1432,
            parentPID: { parents[$0] },
            isApplication: { $0 == 702 }
        )
        XCTAssertEqual(owner, 702)
    }

    func testAudioProcessOwnershipStopsAtCycles() {
        let owner = AudioProcessOwnership.ownerPID(
            startingAt: 10,
            parentPID: { $0 == 10 ? 11 : 10 },
            isApplication: { _ in false }
        )
        XCTAssertNil(owner)
    }

    func testCrashingAudioHelperCannotCrashThermoBarHost() throws {
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thermobar-crashing-audio-helper-\(UUID().uuidString)")
        try "#!/bin/sh\nkill -ABRT $$\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        defer { try? FileManager.default.removeItem(at: helperURL) }

        let exited = expectation(description: "isolated helper exited")
        let route = try IsolatedAudioRoute(
            processID: 1,
            outputUID: "test-output",
            volume: 0.5,
            onEvent: { event in
                if case .failed = event { exited.fulfill() }
            },
            helperURL: helperURL
        )
        _ = route
        wait(for: [exited], timeout: 2)
    }

    func testSilentAudioHelperTimesOutWithoutBlockingCaller() throws {
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thermobar-silent-audio-helper-\(UUID().uuidString)")
        try "#!/bin/sh\nwhile read line; do [ \"$line\" = stop ] && exit 0; done\n"
            .write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        defer { try? FileManager.default.removeItem(at: helperURL) }

        let timedOut = expectation(description: "silent helper timed out")
        let start = Date()
        let route = try IsolatedAudioRoute(
            processID: 1,
            outputUID: "test-output",
            volume: 0.5,
            onEvent: { event in
                if event == .failed("Audio connection timed out") { timedOut.fulfill() }
            },
            helperURL: helperURL,
            startupTimeout: 0.1
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        wait(for: [timedOut], timeout: 1)
        route.stop()
    }

    func testReadyAudioHelperReportsReadyAsynchronously() throws {
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thermobar-ready-audio-helper-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf 'READY\\n'\nwhile read line; do [ \"$line\" = stop ] && exit 0; done\n"
            .write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        defer { try? FileManager.default.removeItem(at: helperURL) }

        let ready = expectation(description: "helper became ready")
        let route = try IsolatedAudioRoute(
            processID: 1,
            outputUID: "test-output",
            volume: 0.5,
            onEvent: { event in
                if event == .ready { ready.fulfill() }
            },
            helperURL: helperURL,
            startupTimeout: 1
        )
        wait(for: [ready], timeout: 1)
        route.stop()
    }

    func testOutputSwitchWaitsForGracefulHelperCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermobar-audio-stop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        let marker = directory.appendingPathComponent("stopped")
        try "#!/bin/sh\nprintf 'READY\\n'\nwhile read line; do\nif [ \"$line\" = stop ]; then printf clean > '\(marker.path)'; exit 0; fi\ndone\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let ready = expectation(description: "helper ready")
        let route = try IsolatedAudioRoute(processID: 1, outputUID: "test-output", volume: 1,
            onEvent: { if $0 == .ready { ready.fulfill() } }, helperURL: helper)
        wait(for: [ready], timeout: 1)
        let start = Date()
        route.stop(waitForExit: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "clean")
    }

    func testAudioHelperReceivesStableIdentityAndLatestGain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mybar-audio-identity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        let marker = directory.appendingPathComponent("commands")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(marker.path)'\nprintf 'READY\\n'\nwhile read line; do printf '%s\\n' \"$line\" >> '\(marker.path)'; [ \"$line\" = stop ] && exit 0; done\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let ready = expectation(description: "helper ready")
        let route = try IsolatedAudioRoute(processID: 42, outputUID: "headphones with spaces", volume: 0.7,
            onEvent: { if $0 == .ready { ready.fulfill() } }, helperURL: helper)
        wait(for: [ready], timeout: 1)
        route.volume = 0.2
        route.volume = 0
        route.stop(waitForExit: true)
        let commands = try String(contentsOf: marker, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(Array(commands.prefix(6)), ["--pid", "42", "--output-uid", "headphones with spaces", "--volume", "0.7"])
        XCTAssertTrue(commands.contains("volume 0.2"))
        XCTAssertTrue(commands.contains("volume 0.0"))
        XCTAssertFalse(commands.contains("--process"))
        XCTAssertFalse(commands.contains("--device"))
    }
}

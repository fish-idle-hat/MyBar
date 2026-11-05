import AppKit
import AVFAudio
import CoreAudio
import Darwin
import XCTest
import TypingFeedbackProtocol
@testable import TheBarTypingHelper
@testable import ThermoBar

final class TypingFeedbackTests: XCTestCase {
    private func output(_ transport: UInt32, _ terminal: UInt32) -> TypingOutput {
        TypingOutput(id: 12, uid: "test-output", name: "Device", transport: transport, terminals: [terminal])
    }
    func testOnlyBluetoothHeadphonesAreAutomaticallyEligible() {
        XCTAssertTrue(output(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeHeadphones).isAllowed(confirmed: []))
        XCTAssertTrue(output(kAudioDeviceTransportTypeBluetoothLE, kAudioStreamTerminalTypeHeadphones).isAllowed(confirmed: []))
        XCTAssertFalse(output(kAudioDeviceTransportTypeBuiltIn, kAudioStreamTerminalTypeHeadphones).isAllowed(confirmed: ["test-output"]))
        XCTAssertFalse(output(kAudioDeviceTransportTypeUSB, kAudioStreamTerminalTypeHeadphones).isAllowed(confirmed: ["test-output"]))
        XCTAssertFalse(output(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeSpeaker).isAllowed(confirmed: ["test-output"]))
        XCTAssertFalse(TypingOutput(id: 12, uid: "mixed", name: "Mixed", transport: kAudioDeviceTransportTypeBluetooth,
                                   terminals: [kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeSpeaker]).isAllowed(confirmed: ["mixed"]))
        XCTAssertFalse(output(kAudioDeviceTransportTypeBluetooth, 0).isAllowed(confirmed: []))
        XCTAssertTrue(output(kAudioDeviceTransportTypeBluetooth, 0).isAllowed(confirmed: ["test-output"]))
        XCTAssertFalse(output(kAudioDeviceTransportTypeBluetooth, 0).isAllowed(confirmed: ["some-other-device"]))
    }
    func testDefaultsAreOffAndMalformedPreferencesAreBounded() {
        var settings = TypingFeedbackSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.sound, "Gateron Ink Red")
        settings.sound = "../../other-file"; settings.volume = .nan
        settings.confirmedHeadphoneUIDs = (0..<100).map(String.init)
        settings.sanitize()
        XCTAssertEqual(settings.sound, "Gateron Ink Red"); XCTAssertEqual(settings.volume, 0.15)
        XCTAssertEqual(settings.confirmedHeadphoneUIDs.count, 16)
        XCTAssertNil(MechanicalKeySound.url(for: "../../other-file"))
        settings.enabled = true; settings.sound = "Pop"; settings.volume = 0.22
        settings.sanitize()
        XCTAssertEqual(settings.sound, "Gateron Ink Red", "Old notification sounds migrate without changing opt-in or gain")
        XCTAssertTrue(settings.enabled); XCTAssertEqual(settings.volume, 0.22)
    }
    func testOnlyFreshFixedSizePulseMessagesAreAccepted() {
        let now = 100.0
        XCTAssertTrue(TypingFeedbackPacket.freshPulse(TypingFeedbackPacket.pulse(at: now), now: now + 0.01))
        let preview = TypingFeedbackPacket.pulse(at: now, isPreview: true)
        XCTAssertEqual(preview.first, 0x50)
        XCTAssertTrue(TypingFeedbackPacket.freshPulse(preview, now: now + 0.01))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(preview, now: now + 0.051))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(Data([0x58]) + preview.dropFirst(), now: now))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(TypingFeedbackPacket.pulse(at: now), now: now + 0.051))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(TypingFeedbackPacket.pulse(at: now), now: now - 1))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(TypingFeedbackPacket.pulse(at: .nan), now: now))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(Data([0x4B]), now: now))
        XCTAssertFalse(TypingFeedbackPacket.freshPulse(Data(repeating: 0, count: 1_000), now: now))
    }
    func testEveryMechanicalSwitchVariationDecodesToShortImmediateFinitePCM() throws {
        XCTAssertEqual(MechanicalKeySound.names.count, 8)
        for sound in MechanicalKeySound.names {
          let urls = MechanicalKeySound.urls(for: sound)
          XCTAssertEqual(urls.count, 3, sound)
          for url in urls {
            let samples = try TypingClickMixer.load(url: url, sampleRate: 48_000)
            XCTAssertFalse(samples.isEmpty, sound)
            XCTAssertLessThanOrEqual(samples.count, 7_200)
            XCTAssertTrue(samples.allSatisfy(\.isFinite), sound)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertEqual(peak, 0.85, accuracy: 0.001, "Every bundled switch should have an audible, matched peak: \(sound)")
            XCTAssertEqual(samples[0], 0, accuracy: 0.00001)
            XCTAssertEqual(samples[samples.count - 1], 0, accuracy: 0.00001)
            let onset = try XCTUnwrap(samples.firstIndex { abs($0) > 0.0001 }, sound)
            XCTAssertLessThan(onset / 2, 48, "No leading silence should delay the switch transient: \(sound)")
          }
        }
    }
    func testSamplePreparationRemovesLeadingSilenceWithoutLosingTheTransient() throws {
        let source = [Float](repeating: 0, count: 4_800) + [Float](repeating: 0.4, count: 9_600)
        let prepared = try TypingClickMixer.prepare(source, inputRate: 48_000, sampleRate: 48_000)
        XCTAssertEqual(prepared.count, 7_200)
        XCTAssertLessThan(try XCTUnwrap(prepared.firstIndex { abs($0) > 0.01 }), 48)
        XCTAssertThrowsError(try TypingClickMixer.prepare([Float](repeating: 0, count: 100), inputRate: 48_000, sampleRate: 48_000))
        XCTAssertThrowsError(try TypingClickMixer.prepare([0, .nan, 1, 0], inputRate: 48_000, sampleRate: 48_000))
    }
    func testQuietAndLoudRecordingsMatchWithoutChangingUserGain() throws {
        for level: Float in [0.034, 0.1, 0.24, 0.45] {
            let samples = try TypingClickMixer.prepare([Float](repeating: level, count: 9_600), inputRate: 48_000, sampleRate: 48_000)
            XCTAssertEqual(samples.max()!, 0.85, accuracy: 0.001)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)); buffer.frameLength = 512
            let mixer = TypingClickMixer(samples: samples, volume: 0.2)
            mixer.trigger(); mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            XCTAssertEqual(buffer.floatChannelData![0][100], 0.17, accuracy: 0.001)
        }
        let tiny = try TypingClickMixer.prepare([Float](repeating: 0.0001, count: 9_600), inputRate: 48_000, sampleRate: 48_000)
        XCTAssertLessThanOrEqual(tiny.max()!, 0.0001 * 32 + 0.000001, "Do not amplify almost-silent/noisy sources without bound")
    }
    func testStackPulseUsesTheSameFreshAnonymousProtocol() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2_000 {
            let now = ProcessInfo.processInfo.systemUptime
            TypingFeedbackPacket.sendPulse(to: pair[0], at: now)
            let count = recv(pair[1], &bytes, bytes.count, MSG_DONTWAIT)
            XCTAssertEqual(count, 9)
            XCTAssertTrue(TypingFeedbackPacket.freshPulse(Data(bytes.prefix(max(0, count))), now: ProcessInfo.processInfo.systemUptime))
        }
        print(String(format: "TYPING_IPC_BENCHMARK: send + receive %.4f ms (not acoustic latency)", (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 2_000))
    }
    func testSwitchVariationsRotateWithoutReadingWhichKeyWasPressed() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)); buffer.frameLength = 256
        let mixer = TypingClickMixer(variants: [0.2, 0.4, 0.6].map { [Float](repeating: Float($0), count: 128) }, volume: 0.5)
        for expected: Float in [0.1, 0.2, 0.3, 0.1] {
            mixer.trigger(); mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            XCTAssertEqual(buffer.floatChannelData![0][0], expected, accuracy: 0.0001)
        }
    }
    func testPreviewsAlwaysUseTheSameRecordingAndNeverStack() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)); buffer.frameLength = 32
        let mixer = TypingClickMixer(variants: [0.2, 0.4, 0.6].map { [Float](repeating: Float($0), count: 128) }, volume: 0.5)
        for _ in 0..<3 {
            mixer.trigger(isPreview: true)
            mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            XCTAssertEqual(buffer.floatChannelData![0][0], 0.1, accuracy: 0.0001)
            for _ in 0..<10 { mixer.trigger(isPreview: true) }
            mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            XCTAssertEqual(buffer.floatChannelData![0][0], 0.1, accuracy: 0.0001, "Rapid preview clicks must not double the amplitude")
            mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            XCTAssertEqual(buffer.floatChannelData![0][0], 0, "Preview ends without a queued replay")
        }
    }
    func testMixerIsSilentUntilTriggeredAndRouteInvalidationClearsVoices() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let mixer = TypingClickMixer(samples: [Float](repeating: 0.4, count: 512), volume: 0.2)
        mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        XCTAssertEqual(buffer.floatChannelData![0][0], 0)
        mixer.trigger(); mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.08, accuracy: 0.00001)
        mixer.setAllowed(false); mixer.trigger()
        mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        XCTAssertEqual(buffer.floatChannelData![0][0], 0)
        mixer.setAllowed(true)
        mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        XCTAssertEqual(buffer.floatChannelData![0][0], 0, "Old clicks cannot replay after reconnecting")
    }
    func testOverlappingVoicesAreBoundedForInterleavedOutput() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)); buffer.frameLength = 128
        let mixer = TypingClickMixer(samples: [Float](repeating: 1, count: 256), volume: 0.5)
        for _ in 0..<100 { mixer.trigger() }
        mixer.render(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 256)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.85 })
    }
    @MainActor
    func testOffManagerDoesNotEnableMonitoringOrLaunchAudio() throws {
        let suite = "TypingFeedbackTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var queriedPermission = false, queriedOutput = false
        let manager = TypingFeedbackManager(defaults: defaults, outputProvider: { queriedOutput = true; return nil }, permissionCheck: { queriedPermission = true; return false })
        var state = TypingFeedbackState()
        manager.onChange = { state = $0 }
        manager.start()
        manager.resumeIfAuthorized()
        XCTAssertFalse(manager.settings.enabled); XCTAssertFalse(state.ready)
        XCTAssertTrue(state.status.hasPrefix("Off"))
        XCTAssertFalse(queriedPermission); XCTAssertFalse(queriedOutput)
        manager.stop()
    }
    @MainActor
    func testPermissionRecoveryNeedsApprovalAndDoesNotPromptOrEnableItself() async throws {
        let suite = "TypingRecoveryTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = TypingFeedbackSettings(); settings.enabled = true
        defaults.set(try PropertyListEncoder().encode(settings), forKey: "TheBar.TypingFeedback.v1")
        var allowed = false, requestedPermission = false
        let headphones = output(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeHeadphones)
        let manager = TypingFeedbackManager(defaults: defaults, helperURL: URL(fileURLWithPath: "/usr/bin/false"),
                                            outputProvider: { headphones }, permissionCheck: { allowed })
        manager.onPermissionPrompt = { requestedPermission = true }
        let waiting = expectation(description: "permission accurately reported as missing")
        let resumed = expectation(description: "helper attempted only after real approval")
        manager.onChange = { state in
            if state.permissionNeeded { XCTAssertFalse(state.listening); waiting.fulfill() }
            if state.status.hasPrefix("Typing audio stopped") { resumed.fulfill() }
        }
        manager.start()
        await fulfillment(of: [waiting], timeout: 2)
        allowed = true
        manager.resumeIfAuthorized()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertFalse(requestedPermission)
        manager.stop()
    }
    @MainActor
    func testFailedHelperCannotCrashOrBlockTheBarHost() async throws {
        let suite = "TypingCrashTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let headphones = output(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeHeadphones)
        let manager = TypingFeedbackManager(defaults: defaults, helperURL: URL(fileURLWithPath: "/usr/bin/false"),
                                            outputProvider: { headphones }, permissionCheck: { true })
        let stopped = expectation(description: "helper fails independently")
        manager.onChange = { state in
            if state.status.hasPrefix("Typing audio stopped") { XCTAssertFalse(state.ready); stopped.fulfill() }
        }
        manager.setEnabled(true)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(manager.settings.enabled, "The request is retained, but automatic crash/retry loops are forbidden")
        manager.stop()
    }
    @MainActor
    func testSoundPanelAllowsPreviewAndChoiceBeforeTypingPermission() throws {
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        details.installSoundControlView(SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize)))
        let soundTab = try XCTUnwrap(details.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Sound tab" })
        soundTab.performClick(nil)
        XCTAssertTrue(details.isSoundTabSelected)
        XCTAssertEqual(details.frame.height, 326)
        let panel = TypingFeedbackView(frame: NSRect(x: 0, y: 0, width: 336, height: 76))
        let preview = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Preview typing sound" })
        XCTAssertTrue(preview.isEnabled, "Manual audio preview must not require global keyboard permission")
        var blocked = TypingFeedbackState()
        blocked.settings.enabled = true; blocked.permissionNeeded = true
        panel.update(blocked)
        let allow = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Allow typing Input Monitoring" })
        XCTAssertFalse(allow.isHidden)
        XCTAssertTrue(preview.isEnabled)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 276))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = (appearance == .aqua ? NSColor.white : NSColor(calibratedWhite: 0.13, alpha: 1)).cgColor
            let sound = SoundControlView(frame: canvas.bounds); sound.appearance = NSAppearance(named: appearance)
            canvas.addSubview(sound); sound.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 3_000)
            if ProcessInfo.processInfo.environment["TYPING_FEEDBACK_PREVIEW"] == "1" {
                try png.write(to: URL(fileURLWithPath: "/private/tmp/typing-feedback-\(appearance.rawValue).png"))
            }
        }
    }
    @MainActor
    func testSoundPickerFollowsInheritedAppearanceAndKeepsReadableContrast() throws {
        let picker = TypingSoundPickerView(selected: "Cherry MX Blue")
        picker.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: picker.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = picker
        picker.appearance = nil
        defer { window.close() }
        var backgrounds: [Double] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            picker.display()
            let background = try XCTUnwrap(NSColor(cgColor: XCTUnwrap(picker.layer?.backgroundColor)))
            let button = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first)
            let titleColor = try XCTUnwrap(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            var contrast = 0.0
            var luminance = 0.0
            var colorsResolved = false
            picker.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let bg = background.usingColorSpace(.sRGB), let fg = titleColor.usingColorSpace(.sRGB) else { return }
                colorsResolved = true
                func brightness(_ color: NSColor) -> Double {
                    func linear(_ component: CGFloat) -> Double {
                        let c = Double(component)
                        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                    }
                    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                }
                luminance = brightness(bg)
                let foreground = brightness(fg)
                contrast = (max(luminance, foreground) + 0.05) / (min(luminance, foreground) + 0.05)
            }
            XCTAssertTrue(colorsResolved)
            XCTAssertGreaterThanOrEqual(contrast, 4.5)
            backgrounds.append(luminance)
            if ProcessInfo.processInfo.environment["TYPING_PICKER_PREVIEW"] == "1" {
                let bitmap = try XCTUnwrap(picker.bitmapImageRepForCachingDisplay(in: picker.bounds))
                picker.cacheDisplay(in: picker.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/mybar-typing-picker-\(appearance.rawValue).png"))
            }
        }
        XCTAssertGreaterThan(backgrounds[0], backgrounds[1])
        XCTAssertEqual(backgrounds[0], backgrounds[2], accuracy: 0.001)
    }
    @MainActor
    func testSoundPickerChoicesStayInsidePanelWithoutCoveringTooltips() throws {
        let picker = TypingSoundPickerView(selected: "Cherry MX Blue")
        let buttons = picker.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 8)
        for button in buttons {
            XCTAssertTrue(picker.bounds.contains(button.frame))
            XCTAssertNil(button.toolTip)
            XCTAssertFalse((button.accessibilityHelp() ?? "").isEmpty)
        }
        XCTAssertEqual(buttons.filter { $0.title.hasPrefix("✓") }.count, 1)
    }
    @MainActor
    func testInlineSoundChoicesRemainUsableAcrossSnapshotUpdates() throws {
        let canvas = NSView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        let sound = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        canvas.addSubview(sound)
        var selected: String?
        sound.typingFeedbackView.onSound = { selected = $0 }
        let button = try XCTUnwrap(sound.typingFeedbackView.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Mechanical keyboard sound" })
        button.performClick(nil)
        let choices = try XCTUnwrap(sound.subviews.compactMap { $0 as? TypingSoundPickerView }.first)
        XCTAssertEqual(choices.subviews.compactMap { $0 as? NSButton }.count, 8)
        XCTAssertLessThanOrEqual(choices.frame.maxY, sound.bounds.height)
        for button in choices.subviews.compactMap({ $0 as? NSButton }) {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: canvas)
            XCTAssertTrue(sound.hitTest(point) === button, "Every choice must be reachable by an actual mouse hit")
        }
        sound.update(SoundControlSnapshot())
        XCTAssertNotNil(choices.superview)
        let tink = try XCTUnwrap(choices.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Select Cherry MX Blue typing sound" })
        XCTAssertTrue(tink.isEnabled); tink.performClick(nil)
        XCTAssertEqual(selected, "Cherry MX Blue")
        XCTAssertEqual(sound.typingFeedbackView.selectedSound, "Cherry MX Blue")
        XCTAssertNil(choices.superview)
    }
    @MainActor
    func testManualPreviewStartsWithoutTurningOnOrRequestingKeyMonitoring() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("typing-preview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = folder.appendingPathComponent("fake-helper")
        try "#!/bin/sh\nprintf 'READY\\n'\nexec /bin/sleep 2\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "TypingPreviewTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let headphones = output(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeHeadphones)
        let manager = TypingFeedbackManager(defaults: defaults, helperURL: fixture, outputProvider: { headphones }, permissionCheck: { false })
        var requestedPermission = false
        manager.onPermissionPrompt = { requestedPermission = true }
        let preview = expectation(description: "manual preview without event tap")
        manager.onChange = { state in
            if state.status.hasPrefix("Preview sent") {
                XCTAssertTrue(state.ready); XCTAssertFalse(state.listening); preview.fulfill()
            }
        }
        manager.preview()
        await fulfillment(of: [preview], timeout: 2)
        XCTAssertFalse(manager.settings.enabled); XCTAssertFalse(requestedPermission)
        try await Task.sleep(nanoseconds: 550_000_000)
        var warmState = TypingFeedbackState()
        manager.onChange = { warmState = $0 }
        manager.setVolume(0.2)
        XCTAssertTrue(warmState.ready, "A second preview must not cold-start after the old 0.4 second timeout")
        manager.endPreview()
        XCTAssertFalse(warmState.ready, "Closing the menu releases an unmonitored preview stream")
        XCTAssertFalse(warmState.listening)
        manager.stop()
    }
    func testIdleAndActiveRenderBenchmark() throws {
        guard ProcessInfo.processInfo.environment["TYPING_FEEDBACK_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in renderer microbenchmark") }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)); buffer.frameLength = 512
        let mixer = TypingClickMixer(variants: try MechanicalKeySound.urls(for: MechanicalKeySound.defaultName).map { try TypingClickMixer.load(url: $0, sampleRate: 48_000) }, volume: 0.15)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2_000 { mixer.render(list) }
        let idle = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 2_000
        let activeStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2_000 { mixer.trigger(); mixer.render(list) }
        let active = (ProcessInfo.processInfo.systemUptime - activeStart) * 1_000 / 2_000
        print(String(format: "TYPING_BENCHMARK: idle %.4f ms / 512 frames; active %.4f ms / 512 frames", idle, active))
        XCTAssertLessThan(active, 10)
    }
}

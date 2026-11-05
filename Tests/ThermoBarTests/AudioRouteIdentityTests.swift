import CoreAudio
import XCTest
@testable import ThermoBarAudioHelper

final class AudioRouteIdentityTests: XCTestCase {
    func testMissingIdentityFailsClosedWithoutChoosingDefault() {
        XCTAssertNil(AudioRouteIdentity.processObject(for: 0))
        XCTAssertNil(AudioRouteIdentity.processObject(for: -1))
        XCTAssertNil(AudioRouteIdentity.outputDevice(for: ""))
        XCTAssertNil(AudioRouteIdentity.outputDevice(for: "missing-mybar-output-\(UUID())"))
    }

    func testDefaultOutputUIDResolvesInCurrentClient() throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try XCTSkipUnless(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device) == noErr && device != kAudioObjectUnknown,
            "No audio device in this test environment")
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), noErr)
        let identifier = try XCTUnwrap(uid).takeRetainedValue() as String
        XCTAssertEqual(AudioRouteIdentity.outputDevice(for: identifier), device)
    }
}

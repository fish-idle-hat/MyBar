import CoreAudio
import Foundation

// Never transfer AudioObjectIDs between processes or fall back to a different
// output when the requested headphones disappear.
enum AudioRouteIdentity {
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        guard pid > 0 else { return nil }
        var value = pid
        return withUnsafePointer(to: &value) {
            translate(kAudioHardwarePropertyTranslatePIDToProcessObject,
                      qualifierSize: UInt32(MemoryLayout<pid_t>.size), qualifier: $0)
        }
    }

    static func outputDevice(for uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        var value = uid as CFString
        return withUnsafePointer(to: &value) {
            translate(kAudioHardwarePropertyTranslateUIDToDevice,
                      qualifierSize: UInt32(MemoryLayout<CFString>.size), qualifier: $0)
        }
    }

    private static func translate(_ selector: AudioObjectPropertySelector,
                                  qualifierSize: UInt32, qualifier: UnsafeRawPointer) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            qualifierSize, qualifier, &size, &result) == noErr,
            result != kAudioObjectUnknown else { return nil }
        return result
    }
}

import Foundation
import CoreAudio
import Darwin
import TypingFeedbackProtocol

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}
func emit(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }

// Packaging smoke test: decode bundled assets only; no device, key tap or audio output.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--validate-sounds" {
    do {
        var count = 0
        for name in MechanicalKeySound.names {
            let urls = MechanicalKeySound.urls(for: name)
            guard urls.count == 3 else { throw CocoaError(.fileNoSuchFile) }
            for url in urls { _ = try TypingClickMixer.load(url: url, sampleRate: 48_000); count += 1 }
        }
        emit("VALID|\(MechanicalKeySound.names.count) switch packs|\(count) recordings"); exit(0)
    } catch { emit("ERROR|Missing or invalid bundled switch recording"); exit(4) }
}

final class TypingOutputSession {
    let mixer: TypingClickMixer
    let device: AudioObjectID
    private let format: AudioStreamBasicDescription
    private var ioProc: AudioDeviceIOProcID?
    init(output: TypingOutput, sound: String, volume: Float) throws {
        device = output.id
        guard let format = TypingOutputInventory.scalar(device, kAudioDevicePropertyStreamFormat,
                    scope: kAudioDevicePropertyScopeOutput, as: AudioStreamBasicDescription.self),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              (1...2).contains(format.mChannelsPerFrame), MechanicalKeySound.urls(for: sound).count == 3
        else { throw CocoaError(.featureUnsupported) }
        self.format = format
        mixer = TypingClickMixer(variants: try MechanicalKeySound.urls(for: sound).map {
            try TypingClickMixer.load(url: $0, sampleRate: format.mSampleRate)
        }, volume: volume)
        let mixer = self.mixer
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil, { _, _, _, outputData, _ in
            mixer.render(UnsafeMutableAudioBufferListPointer(outputData))
        }) == noErr, let ioProc else { throw CocoaError(.featureUnsupported) }
        do { try disableInput(for: ioProc) }
        catch { AudioDeviceDestroyIOProcID(device, ioProc); self.ioProc = nil; throw error }
        guard AudioDeviceStart(device, ioProc) == noErr else {
            AudioDeviceDestroyIOProcID(device, ioProc); self.ioProc = nil
            throw CocoaError(.featureUnsupported)
        }
        // The IOProc belongs to this physical device, not the default-output audio unit.
        // Core Audio cannot silently move this stream to the Mac's speakers.
    }
    func formatIsUnchanged() -> Bool {
        guard let current = TypingOutputInventory.scalar(device, kAudioDevicePropertyStreamFormat,
                   scope: kAudioDevicePropertyScopeOutput, as: AudioStreamBasicDescription.self) else { return false }
        return current.mSampleRate == format.mSampleRate && current.mChannelsPerFrame == format.mChannelsPerFrame
            && current.mFormatID == format.mFormatID && current.mFormatFlags == format.mFormatFlags
            && current.mBitsPerChannel == format.mBitsPerChannel
    }
    private func disableInput(for ioProc: AudioDeviceIOProcID) throws {
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr else { throw CocoaError(.featureUnsupported) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count <= 64 else { throw CocoaError(.featureUnsupported) }
        if count == 0 { return }
        let length = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (count - 1) * MemoryLayout<UInt32>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: length)
        let usage = memory.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(length), memory) == noErr else { throw CocoaError(.featureUnsupported) }
        // Never open the headset microphone or force its low-quality hands-free profile.
    }
    deinit {
        mixer.setAllowed(false)
        if let ioProc { AudioDeviceStop(device, ioProc); AudioDeviceDestroyIOProcID(device, ioProc) }
    }
}

guard let uid = argument("--uid"), let sound = argument("--sound"), MechanicalKeySound.names.contains(sound),
      let parentText = argument("--parent"), let parent = Int32(parentText), parent == getppid(),
      let volumeText = argument("--volume"), let volume = Float(volumeText), volume.isFinite, (0...0.5).contains(volume),
      let output = TypingOutputInventory.defaultOutput(), output.uid == uid,
      output.isAllowed(confirmed: CommandLine.arguments.contains("--confirmed-headphones") ? [uid] : []) else {
    emit("ERROR|Bluetooth headphones are not the current output"); exit(2)
}

do {
    let session = try TypingOutputSession(output: output, sound: sound, volume: volume)
    let queue = DispatchQueue(label: "TheBar.typing-helper", qos: .userInteractive)
    var stopping = false // Accessed only by the helper queue.
    func requestStop() {
        stopping = true
        session.mixer.setAllowed(false)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetMain()) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    func validRoute() -> Bool {
        guard let current = TypingOutputInventory.defaultOutput() else { return false }
        return current.id == output.id && current.uid == uid && current.isBluetooth && session.formatIsUnchanged()
            && current.isAllowed(confirmed: CommandLine.arguments.contains("--confirmed-headphones") ? [uid] : [])
    }
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
        requestStop()
        emit("STOPPED|Output changed; waiting for Bluetooth headphones")
    }
    var registrations = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices].map {
        (AudioObjectID(kAudioObjectSystemObject), AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0))
    }
    registrations += [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate].map {
        (output.id, AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0))
    }
    registrations.append((output.id, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)))
    for index in registrations.indices {
        guard AudioObjectAddPropertyListenerBlock(registrations[index].0, &registrations[index].1, queue, listener) == noErr else {
            throw CocoaError(.featureUnsupported)
        }
    }
    // Close the setup race: a changed default during decoder/device startup fails closed.
    guard validRoute() else { throw CocoaError(.featureUnsupported) }
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
    input.setEventHandler {
        var bytes = [UInt8](repeating: 0, count: 32)
        for _ in 0..<32 {
            let count = recv(STDIN_FILENO, &bytes, bytes.count, MSG_DONTWAIT)
            guard count > 0 else { break }
            let packet = Data(bytes.prefix(count))
            if packet == Data([0x51]) { requestStop(); break }
            if packet.count == 2, packet.first == 0x56 { session.mixer.setVolume(Float(packet[1]) / 100); continue }
            if TypingFeedbackPacket.freshPulse(packet, now: ProcessInfo.processInfo.systemUptime) {
                session.mixer.trigger(isPreview: packet.first == 0x50)
            }
        }
    }
    input.resume()
    let watchdog = DispatchSource.makeTimerSource(queue: queue)
    watchdog.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
    watchdog.setEventHandler {
        if getppid() != parent || !validRoute() {
            requestStop()
        }
    }
    watchdog.resume()
    // Prime the newly started Bluetooth stream with silence before accepting keys
    // or a preview. This is a one-time setup delay, never a per-key delay.
    let preparation = DispatchSource.makeTimerSource(queue: queue)
    preparation.schedule(deadline: .now() + 0.2)
    preparation.setEventHandler {
        if !stopping {
            if validRoute() { emit("READY") } else { requestStop() }
        }
    }
    preparation.resume()
    CFRunLoopRun()
    session.mixer.setAllowed(false)
    input.cancel(); watchdog.cancel(); preparation.cancel()
    for index in registrations.indices { AudioObjectRemovePropertyListenerBlock(registrations[index].0, &registrations[index].1, queue, listener) }
    withExtendedLifetime(session) {}
} catch {
    emit("ERROR|Typing audio unavailable; no speaker fallback was used")
    exit(3)
}

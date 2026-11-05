import AudioToolbox
import AVFAudio
import CoreAudio
import Darwin
import Foundation

private func emit(_ line: String) {
    guard let data = "\(line)\n".data(using: .utf8) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data)
}

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

final class HelperAudioRoute {
    enum RouteError: Error {
        case coreAudio(String, OSStatus)
        case unsupportedFormat
        case outputUnavailable

        var userMessage: String {
            switch self {
            case .unsupportedFormat: "Unsupported app audio format"
            case .outputUnavailable: "Output device unavailable"
            case let .coreAudio(operation, status): "\(operation) failed (\(status))"
            }
        }
    }

    var volume: Float {
        get { ring?.volume ?? 1 }
        set { ring?.volume = newValue }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ring: StereoFloatRingBuffer?
    private var isStopped = false

    init(processObjectID: AudioObjectID, outputDeviceID: AudioObjectID, volume: Float) throws {
        do {
            try configure(processObjectID: processObjectID, outputDeviceID: outputDeviceID, volume: volume)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        // Let the rendering callback reach zero before releasing the muting tap.
        // This runs in the isolated helper, never on ThermoBar's UI thread.
        if engine.isRunning, let ring {
            ring.fadeOut()
            Thread.sleep(forTimeInterval: 0.025)
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        ring = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func configure(processObjectID: AudioObjectID, outputDeviceID: AudioObjectID, volume: Float) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "TheBar Isolated App Route"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Process tap")

        let tapUID = try stringProperty(tapID, selector: kAudioTapPropertyUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TheBar Private Route",
            kAudioAggregateDeviceUIDKey: "local.thermobar.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "Private audio device"
        )

        var tapDescription = AudioStreamBasicDescription()
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &property, 0, nil, &size, &tapDescription),
            "Tap format"
        )
        guard tapDescription.mFormatID == kAudioFormatLinearPCM,
              tapDescription.mSampleRate > 0,
              tapDescription.mBitsPerChannel == 32,
              tapDescription.mChannelsPerFrame >= 1,
              tapDescription.mChannelsPerFrame <= 2,
              tapDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let sourceFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: tapDescription.mSampleRate,
                  channels: 2,
                  interleaved: false
              )
        else { throw RouteError.unsupportedFormat }

        guard let outputUnit = engine.outputNode.audioUnit else { throw RouteError.outputUnavailable }
        var selectedDevice = outputDeviceID
        try check(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioObjectID>.size)
            ),
            "Output selection"
        )

        let buffer = StereoFloatRingBuffer(
            capacityFrames: max(48_000, Int(tapDescription.mSampleRate * 2)),
            sampleRate: tapDescription.mSampleRate
        )
        buffer.volume = volume
        ring = buffer
        let source = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, outputData in
            buffer.read(into: outputData, frames: Int(frameCount))
            return noErr
        }
        sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)
        // Gain changes are sample-ramped by the source, not stepped by the mixer.
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()

        let channelCount = Int(tapDescription.mChannelsPerFrame)
        let isInterleaved = tapDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
                buffer.write(from: inputData, channels: channelCount, interleaved: isInterleaved)
            },
            "Tap reader"
        )
        try check(AudioDeviceStart(aggregateID, ioProcID), "Tap start")
    }

    private func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var property = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "Tap identifier")
        guard let value else { throw RouteError.outputUnavailable }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw RouteError.coreAudio(operation, status) }
    }
}

final class StereoFloatRingBuffer {
    private let lock = NSLock()
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private let primingFrames: Int
    private let rampFrames: Int
    private var isPrimed = false
    private var isStopping = false
    private var fadeInFrames = 0
    private var currentGain: Float = 0
    private var targetGain: Float = 1

    var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return targetGain }
        set { lock.lock(); targetGain = newValue.isFinite ? min(1, max(0, newValue)) : 0; lock.unlock() }
    }

    func fadeOut() {
        lock.lock()
        isStopping = true
        targetGain = 0
        lock.unlock()
    }

    init(capacityFrames: Int, sampleRate: Double = 48_000) {
        left = [Float](repeating: 0, count: capacityFrames)
        right = [Float](repeating: 0, count: capacityFrames)
        primingFrames = max(1, min(capacityFrames / 2, Int(sampleRate * 0.04)))
        rampFrames = max(1, Int(sampleRate * 0.015))
    }

    func write(from data: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard let first = buffers.first, let firstData = first.mData else { return }
        let frames = interleaved
            ? Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
            : Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        let firstSamples = firstData.assumingMemoryBound(to: Float.self)
        let secondSamples = (!interleaved && buffers.count > 1) ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        for frame in 0..<frames {
            let l = interleaved ? firstSamples[frame * max(1, channels)] : firstSamples[frame]
            let r: Float
            if interleaved, channels > 1 {
                r = firstSamples[frame * channels + 1]
            } else if let secondSamples {
                r = secondSamples[frame]
            } else {
                r = l
            }
            left[writeIndex] = l
            right[writeIndex] = r
            writeIndex = (writeIndex + 1) % left.count
            if availableFrames == left.count {
                readIndex = (readIndex + 1) % left.count
            } else {
                availableFrames += 1
            }
        }
    }

    func read(into data: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        lock.lock()
        defer { lock.unlock() }
        for buffer in buffers {
            if let pointer = buffer.mData { memset(pointer, 0, Int(buffer.mDataByteSize)) }
        }

        guard buffers.count >= 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData
        else { return }
        if !isPrimed {
            guard !isStopping, availableFrames >= max(primingFrames, frames) else { return }
            isPrimed = true
            fadeInFrames = 0
            currentGain = 0
        }
        let count = min(frames, availableFrames)
        let underrun = availableFrames <= frames
        let tailFrames = min(count, rampFrames)
        let gainStep = 1 / Float(rampFrames)
        let leftOutput = leftData.assumingMemoryBound(to: Float.self)
        let rightOutput = rightData.assumingMemoryBound(to: Float.self)
        for frame in 0..<count {
            currentGain += min(gainStep, max(-gainStep, targetGain - currentGain))
            fadeInFrames = min(rampFrames, fadeInFrames + 1)
            var gain = currentGain * Float(fadeInFrames) / Float(rampFrames)
            if underrun, count - frame <= tailFrames {
                gain *= Float(count - frame - 1) / Float(max(1, tailFrames))
            }
            leftOutput[frame] = left[readIndex] * gain
            rightOutput[frame] = right[readIndex] * gain
            readIndex = (readIndex + 1) % left.count
        }
        availableFrames -= count
        if underrun {
            // Recover a useful cushion before fading back in, instead of
            // alternating full-level fragments with zero-filled callbacks.
            isPrimed = false
            currentGain = 0
        }
    }
}

guard let processText = argument("--pid"),
      let processID = pid_t(processText), processID > 0,
      let outputUID = argument("--output-uid"), !outputUID.isEmpty,
      let volumeText = argument("--volume"),
      let initialVolume = Float(volumeText), initialVolume.isFinite, (0...1).contains(initialVolume)
else {
    emit("ERROR|Invalid audio route request")
    exit(2)
}

guard let processObjectID = AudioRouteIdentity.processObject(for: processID),
      let outputDeviceID = AudioRouteIdentity.outputDevice(for: outputUID) else {
    emit("ERROR|App or selected output is no longer available")
    exit(2)
}

do {
    let route = try HelperAudioRoute(
        processObjectID: processObjectID,
        outputDeviceID: outputDeviceID,
        volume: initialVolume
    )
    emit("READY")
    while let command = readLine() {
        let parts = command.split(separator: " ", maxSplits: 1)
        if parts.first == "stop" { break }
        if parts.first == "volume", parts.count == 2, let value = Float(parts[1]) {
            route.volume = value
        }
    }
    route.stop()
} catch let error as HelperAudioRoute.RouteError {
    emit("ERROR|\(error.userMessage)")
    exit(3)
} catch {
    emit("ERROR|Audio route unavailable")
    exit(4)
}

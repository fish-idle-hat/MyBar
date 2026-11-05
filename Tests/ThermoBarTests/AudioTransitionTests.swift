import AudioToolbox
import AVFAudio
import XCTest
@testable import ThermoBarAudioHelper

final class AudioTransitionTests: XCTestCase {
    private func write(_ samples: [Float], to ring: StereoFloatRingBuffer) {
        samples.withUnsafeBytes { bytes in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count),
                mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)))
            ring.write(from: &input, channels: 1, interleaved: false)
        }
    }

    private func read(_ frames: Int, from ring: StereoFloatRingBuffer) -> [Float] {
        let data = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(data.unsafeMutablePointer) }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        data[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: left)
        data[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: right)
        ring.read(into: data.unsafeMutablePointer, frames: frames)
        let result = Array(UnsafeBufferPointer(start: left, count: frames))
        XCTAssertEqual(result, Array(UnsafeBufferPointer(start: right, count: frames)))
        return result
    }

    func testStartupWaitsForBufferThenFadesInAtBothDeviceRates() {
        for rate in [44_100.0, 48_000.0] {
            let ring = StereoFloatRingBuffer(capacityFrames: 8_192, sampleRate: rate)
            write([Float](repeating: 1, count: 128), to: ring)
            XCTAssertEqual(read(128, from: ring), [Float](repeating: 0, count: 128))
            write([Float](repeating: 1, count: 4_096), to: ring)
            let samples = read(1_024, from: ring)
            XCTAssertLessThan(samples[0], 0.001)
            XCTAssertEqual(samples.last!, 1, accuracy: 0.0001)
            XCTAssertLessThan(zip(samples.dropFirst(), samples).map { abs($0 - $1) }.max()!, 0.004)
        }
    }

    func testUnderrunEndsAtZeroAndReprimesBeforeResuming() {
        let ring = StereoFloatRingBuffer(capacityFrames: 8_192)
        write([Float](repeating: 1, count: 2_048), to: ring)
        _ = read(1_024, from: ring)
        let tail = read(1_024, from: ring)
        XCTAssertEqual(tail.last!, 0)
        XCTAssertLessThan(zip(tail.dropFirst(), tail).map { abs($0 - $1) }.max()!, 0.004)
        write([Float](repeating: 1, count: 128), to: ring)
        XCTAssertEqual(read(128, from: ring), [Float](repeating: 0, count: 128))
        write([Float](repeating: 1, count: 2_048), to: ring)
        XCTAssertLessThan(read(128, from: ring)[0], 0.001)
    }

    func testStopAndVolumeChangesAreRampedNotStepped() {
        let ring = StereoFloatRingBuffer(capacityFrames: 8_192)
        write([Float](repeating: 1, count: 6_144), to: ring)
        _ = read(1_024, from: ring)
        ring.volume = 0.5
        let changed = read(1_024, from: ring)
        XCTAssertGreaterThan(changed[0], 0.99)
        XCTAssertEqual(changed.last!, 0.5, accuracy: 0.0001)
        ring.fadeOut()
        let stopped = read(1_024, from: ring)
        XCTAssertGreaterThan(stopped[0], 0.49)
        XCTAssertEqual(stopped.last!, 0, accuracy: 0.0001)
        XCTAssertLessThan(zip(stopped.dropFirst(), stopped).map { abs($0 - $1) }.max()!, 0.002)
    }

    func testAirPodsToSpeakerSampleRateConversionRemainsClean() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THERMOBAR_AUDIO_RENDER_TEST"] == "1",
                          "Opt in outside restricted sandboxes to load macOS audio components")
        // Exercise the production source -> mixer conversion without playing
        // test audio or changing either physical device's sample rate/volume.
        let ring = StereoFloatRingBuffer(capacityFrames: 48_000, sampleRate: 48_000)
        write((0..<24_000).map { 0.7 * sin(Float($0) * 2 * .pi * 1_000 / 48_000) }, to: ring)
        let engine = AVAudioEngine()
        let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let speakerFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let source = AVAudioSourceNode(format: sourceFormat) { _, _, frames, output in
            ring.read(into: output, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: speakerFormat)
        try engine.enableManualRenderingMode(.offline, format: speakerFormat, maximumFrameCount: 512)
        try engine.start()
        defer { engine.stop() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: 512))
        var samples: [Float] = []
        for _ in 0..<16 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        let steady = Array(samples.suffix(4_410))
        XCTAssertTrue(steady.allSatisfy { $0.isFinite && abs($0) < 0.71 })
        let crossings = zip(steady, steady.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        XCTAssertEqual(crossings, 100, accuracy: 2)
    }
}

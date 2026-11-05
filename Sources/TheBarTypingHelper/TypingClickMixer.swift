import Foundation
import AVFAudio

/// Three predecoded switch recordings and eight fixed voices. No file I/O in rendering.
final class TypingClickMixer {
    private let variants: [[Float]]
    private var positions = [Int](repeating: -1, count: 8)
    private var voiceVariants = [Int](repeating: 0, count: 8)
    private var nextVoice = 1 // Voice zero is reserved for non-overlapping manual previews.
    private var nextVariant = 0
    private let lock = NSLock()
    private var volume: Float
    private var allowed = true

    convenience init(samples: [Float], volume: Float) { self.init(variants: [samples], volume: volume) }
    init(variants: [[Float]], volume: Float) {
        let valid = Array(variants.filter { $0.count >= 2 }.prefix(3))
        self.variants = valid.isEmpty ? [[0, 0]] : valid
        self.volume = volume
    }
    func setAllowed(_ allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.allowed = allowed
        if !allowed { for index in positions.indices { positions[index] = -1 } }
    }
    func setVolume(_ value: Float) { lock.lock(); volume = min(0.5, max(0, value)); lock.unlock() }
    func trigger(isPreview: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard allowed else { return }
        if isPreview {
            guard positions[0] < 0 else { return }
            positions[0] = 0; voiceVariants[0] = 0
            return
        }
        positions[nextVoice] = 0
        voiceVariants[nextVoice] = nextVariant
        nextVariant = (nextVariant + 1) % variants.count
        nextVoice = nextVoice % (positions.count - 1) + 1
    }
    func render(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard allowed, positions.contains(where: { $0 >= 0 }), let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        for frame in 0..<frames {
            var left: Float = 0, right: Float = 0
            for voice in positions.indices where positions[voice] >= 0 {
                let position = positions[voice]
                let samples = variants[voiceVariants[voice]]
                if position + 1 < samples.count {
                    left += samples[position]; right += samples[position + 1]
                    positions[voice] += 2
                } else { positions[voice] = -1 }
            }
            left = min(0.85, max(-0.85, left * volume))
            right = min(0.85, max(-0.85, right * volume))
            var channel = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mNumberChannels)
                for local in 0..<count {
                    let index = frame * count + local
                    if index * MemoryLayout<Float>.size < Int(buffer.mDataByteSize) {
                        data[index] = channel == 0 ? left : right
                    }
                    channel += 1
                }
            }
        }
    }

    static func load(url: URL, sampleRate: Double) throws -> [Float] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { throw CocoaError(.fileReadCorruptFile) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputRate = file.processingFormat.sampleRate
        guard inputRate.isFinite, inputRate > 0,
              file.processingFormat.channelCount >= 1, file.processingFormat.channelCount <= 2 else { throw CocoaError(.fileReadCorruptFile) }
        let capacity = AVAudioFrameCount(min(file.length, AVAudioFramePosition(inputRate * 0.2) + 2))
        guard capacity > 1, let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: pcm, frameCount: capacity)
        guard let channels = pcm.floatChannelData, pcm.frameLength > 1 else { throw CocoaError(.fileReadCorruptFile) }
        var decoded = [Float](repeating: 0, count: Int(pcm.frameLength) * 2)
        for frame in 0..<Int(pcm.frameLength) {
            decoded[frame * 2] = channels[0][frame]
            decoded[frame * 2 + 1] = channels[min(1, Int(pcm.format.channelCount) - 1)][frame]
        }
        return try prepare(decoded, inputRate: inputRate, sampleRate: sampleRate)
    }
    /// Strip encoder padding/leading silence once, retaining 0.2 ms before the transient.
    static func prepare(_ input: [Float], inputRate: Double, sampleRate: Double) throws -> [Float] {
        guard input.count >= 4, input.count % 2 == 0, input.allSatisfy(\.isFinite),
              inputRate.isFinite, sampleRate.isFinite, (8_000...192_000).contains(inputRate),
              (8_000...192_000).contains(sampleRate) else { throw CocoaError(.fileReadCorruptFile) }
        let peak = input.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.00001,
              let first = input.firstIndex(where: { abs($0) >= max(0.0001, peak * 0.015) }) else { throw CocoaError(.fileReadCorruptFile) }
        let start = max(0, first / 2 - Int(inputRate * 0.0002))
        let frames = min(Int(sampleRate * 0.075), Int(Double(input.count / 2 - start - 1) / inputRate * sampleRate))
        guard frames > 1 else { throw CocoaError(.fileReadCorruptFile) }
        var result = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let position = Double(start) + Double(frame) * inputRate / sampleRate
            let base = Int(position), fraction = Float(position - Double(base))
            let envelope = Float(min(1, Double(frame) / max(1, sampleRate * 0.0002), Double(frames - 1 - frame) / max(1, sampleRate * 0.006)))
            for channel in 0..<2 {
                result[frame * 2 + channel] = (input[base * 2 + channel] * (1 - fraction) + input[(base + 1) * 2 + channel] * fraction) * envelope
            }
        }
        // The source recordings range from roughly 0.03 to 0.45 peak. Match their
        // level once at load time, before the user's independent feedback gain.
        // Bound amplification of quiet/noisy assets; the renderer still limits overlaps.
        let renderedPeak = result.reduce(Float(0)) { max($0, abs($1)) }
        let gain = min(32, 0.85 / max(0.00001, renderedPeak))
        for index in result.indices { result[index] *= gain }
        return result
    }
}
